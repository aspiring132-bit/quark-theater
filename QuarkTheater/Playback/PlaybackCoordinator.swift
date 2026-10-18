import AVFoundation
import Combine
import Foundation
@preconcurrency import KSPlayer

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var ksPlayerURL: URL?
    @Published private(set) var ksPlayerOptions: KSOptions?
    @Published private(set) var isPlaying: Bool = false
    public let ksCoordinator = KSVideoPlayer.Coordinator()

    static func shouldCommitSeek(operationToken: UUID, currentToken: UUID, playerMatches: Bool, isCancelled: Bool = false) -> Bool {
        !isCancelled && operationToken == currentToken && playerMatches
    }

    static func shouldClearSeekState(operationToken: UUID, currentToken: UUID, playerMatches: Bool, isCancelled: Bool) -> Bool {
        !isCancelled && operationToken == currentToken && playerMatches
    }

    static func shouldScheduleRetry(currentGeneration: Int, scheduledGeneration: Int?, retryTaskActive: Bool) -> Bool {
        !(retryTaskActive && scheduledGeneration == currentGeneration)
    }

    static func shouldTreatKSFinishAsFailure(_ error: Error?) -> Bool { error != nil }

    static func headersExcludingCookie(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
    }

    static func ksTrackSnapshotChanged(previousIDs: [Int32], currentIDs: [Int32],
                                       previousSelected: Int?, currentSelected: Int?) -> Bool {
        previousIDs != currentIDs || previousSelected != currentSelected
    }

    static func ksSubtitleSelectionIndex(infoIDs: [String], selectedID: String?, trackFallback: Int?) -> Int? {
        if infoIDs.isEmpty { return trackFallback }
        guard let selectedID else { return nil }
        return infoIDs.firstIndex(of: selectedID)
    }

    static func observerBelongsToCurrentPlayback(
        observedPlayer: AVPlayer,
        observedItem: AVPlayerItem,
        currentPlayer: AVPlayer?,
        currentItem: AVPlayerItem?
    ) -> Bool {
        observedPlayer === currentPlayer && observedItem === currentItem
    }

    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isBuffering = false
    @Published private(set) var networkSpeedText: String = ""
    @Published private(set) var ksAudioOptions: [any MediaPlayerTrack] = []
    @Published private(set) var ksSubtitleOptions: [any MediaPlayerTrack] = []
    @Published private(set) var ksSubtitleParts: [SubtitlePart] = []
    @Published private(set) var lastSilentMarkerDate: Date?
    @Published private(set) var selectedAudioIndex: Int?
    @Published private(set) var selectedSubtitleIndex: Int?

    private let client: QuarkClient
    private let accountID: String
    private var currentFile: CloudFile
    private let queue: [CloudFile]
    private let automaticallyPlayNext: Bool
    private let history: HistoryRepository
    private let diagnostics: Diagnostics
    private let retryPolicy = RetryPolicy(maximumRetries: 2, baseDelay: 1)
    private var retryTask: Task<Void, Never>?
    private var retryScheduledGeneration: Int?
    private var retriesUsed = 0
    private var restoredPosition: Double = 0
    private var generation = 0
    private var lastKSAudioIDs: [Int32] = []
    private var lastKSSubtitleIDs: [Int32] = []
    private var lastKSSelectedAudioIndex: Int?
    private var lastKSSelectedSubtitleIndex: Int?

    var hasActivePlayer: Bool {
        ksPlayerURL != nil
    }

    init(client: QuarkClient, accountID: String, file: CloudFile, queue: [CloudFile] = [],
         automaticallyPlayNext: Bool = false, history: HistoryRepository, diagnostics: Diagnostics) {
        self.client = client
        self.accountID = accountID
        self.currentFile = file
        self.queue = queue.isEmpty ? [file] : queue
        self.automaticallyPlayNext = automaticallyPlayNext
        self.history = history
        self.diagnostics = diagnostics
    }

    func start() async {
        guard !isLoading, !hasActivePlayer else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            restoredPosition = try history.history(accountID: accountID, fileID: currentFile.fileId)?.positionSeconds ?? 0
            try await resolveAndPlay(at: restoredPosition)
        } catch is CancellationError {
        } catch {
            report(error)
        }
    }

    func stop() {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        retryScheduledGeneration = nil
        saveProgress()
        detachObservers()
        ksPlayerURL = nil
        ksPlayerOptions = nil
        isPlaying = false
    }

    var canPlayNext: Bool {
        guard let currentIndex = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) else { return false }
        return currentIndex + 1 < queue.count
    }

    func playNext() {
        guard let currentIndex = queue.firstIndex(where: { $0.fileId == currentFile.fileId }),
              currentIndex + 1 < queue.count else { return }
        playFile(queue[currentIndex + 1])
    }

    func playFile(_ file: CloudFile) {
        saveProgress()
        currentFile = file
        restoredPosition = (try? history.history(accountID: accountID, fileID: file.fileId)?.positionSeconds) ?? 0
        message = nil
        retriesUsed = 0
        retryScheduledGeneration = nil
        retryTask?.cancel()
        retryTask = nil
        Task {
            isLoading = true
            defer { isLoading = false }
            do { try await resolveAndPlay(at: restoredPosition) }
            catch is CancellationError { }
            catch { report(error) }
        }
    }

    func saveProgress() {
        let position = safePlaybackTime
        let duration = ksCoordinator.playerLayer?.player.duration ?? 0
        guard position > 5, duration > 10 else { return }
        let completed = duration > 0 && position >= duration * 0.95
        let record = WatchHistory(accountId: accountID, fileId: currentFile.fileId,
            fileName: currentFile.name,
            positionSeconds: completed ? duration : position, durationSeconds: duration,
            lastWatchedAt: Date(), completed: completed)
        do { try history.save(record) }
        catch { diagnostics.recordError(error, context: "播放进度保存") }
    }

    func togglePlayPause() {
        if let p = ksCoordinator.playerLayer?.player {
            if p.isPlaying {
                ksCoordinator.playerLayer?.pause()
                isPlaying = false
            } else {
                ksCoordinator.playerLayer?.play()
                isPlaying = true
            }
        }
    }

    func retry() {
        retryTask?.cancel()
        retryScheduledGeneration = nil
        retriesUsed = 0
        retryTask = Task { await startRetryLoop() }
    }

    /// Handles one discrete Siri Remote skip.
    func seek(direction: PlayerSeekDirection, interval: Int) {
        guard let ksPlayer = ksCoordinator.playerLayer?.player else { return }
        let current = ksPlayer.currentPlaybackTime
        let duration = ksPlayer.duration
        guard let target = PlayerSeekMath.nextTarget(current: current, pending: nil, inFlight: nil,
                                                     direction: direction, interval: interval, duration: duration) else { return }
        ksCoordinator.seek(time: target)
        diagnostics.record(category: .playback, level: .debug, event: .playbackSeek,
                           metadata: [.playbackTimeSeconds(target)])
    }

    var currentPlayingFile: CloudFile { currentFile }
    var playlistQueue: [CloudFile] { queue }

    var audioTrackNames: [String] {
        ksAudioOptions.enumerated().map { index, track in
            var components: [String] = []
            if !track.name.isEmpty && track.name.lowercased() != "und" {
                components.append(track.name)
            } else if let lang = (track as? FFmpegAssetTrack)?.languageCode, !lang.isEmpty, lang.lowercased() != "und" {
                components.append(lang.uppercased())
            }
            if let ffmpegTrack = track as? FFmpegAssetTrack {
                let codec = ffmpegTrack.codecName.uppercased()
                if let audioFormat = ffmpegTrack.audioDescriptor?.audioFormat {
                    let channels = audioFormat.channelCount
                    let layoutDesc: String
                    switch channels {
                    case 1: layoutDesc = "单声道"
                    case 2: layoutDesc = "立体声"
                    case 6: layoutDesc = "5.1声道"
                    case 8: layoutDesc = "7.1全景声"
                    default: layoutDesc = "\(channels)声道"
                    }
                    if !codec.isEmpty {
                        components.append("\(codec) (\(layoutDesc))")
                    } else {
                        components.append(layoutDesc)
                    }
                } else if !codec.isEmpty {
                    components.append(codec)
                }
            }
            let base = components.joined(separator: " · ")
            return base.isEmpty ? "音轨 \(index + 1)" : base
        }
    }

    var subtitleTrackNames: [String] {
        let modelNames = ksCoordinator.subtitleModel.subtitleInfos.map(\.name)
        if !modelNames.isEmpty { return modelNames }
        return ksSubtitleOptions.enumerated().map { index, track in
            track.name.isEmpty ? "字幕 \(index + 1)" : track.name
        }
    }

    func selectAudio(_ index: Int) {
        guard ksAudioOptions.indices.contains(index), let ksPlayer = ksCoordinator.playerLayer?.player else { return }
        ksPlayer.select(track: ksAudioOptions[index])
        selectedAudioIndex = index
        recordAudioSnapshot(level: .notice)
    }

    func selectSubtitle(_ index: Int?) {
        guard let ksPlayer = ksCoordinator.playerLayer?.player else { return }
        if let index, index >= 0,
           (ksSubtitleOptions.indices.contains(index) || ksCoordinator.subtitleModel.subtitleInfos.indices.contains(index)) {
            let infos = ksCoordinator.subtitleModel.subtitleInfos
            if infos.indices.contains(index) {
                ksCoordinator.subtitleModel.selectedSubtitleInfo = infos[index]
            } else {
                ksPlayer.select(track: ksSubtitleOptions[index])
            }
            selectedSubtitleIndex = index
        } else {
            ksCoordinator.subtitleModel.selectedSubtitleInfo = nil
            ksSubtitleParts = []
            ksSubtitleOptions.forEach { $0.isEnabled = false }
            selectedSubtitleIndex = nil
        }
    }

    func markSilent() {
        let now = Date()
        lastSilentMarkerDate = now
        diagnostics.record("用户在播放 \(currentFile.name) 时标记了【无声】。当前音轨：\(selectedAudioIndex.map { "\($0)" } ?? "未选")，路由：\(currentAudioRoute)")
    }

    private func resolveAndPlay(at position: Double) async throws {
        generation += 1
        let requestGeneration = generation
        let requestedFile = currentFile
        message = nil
        let resource: PlaybackResource
        do {
            resource = try await client.playbackResource(fileID: requestedFile.id)
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            if retriesUsed == 0,
               let retryDelay = retryPolicy.delay(for: error, retriesUsed: 0) {
                retriesUsed += 1
                retryScheduledGeneration = generation
                message = "正在重新连接视频流…"
                let retryGen = generation
                retryTask = Task { [weak self] in
                    defer {
                        Task { @MainActor in
                            guard let self, self.generation == retryGen else { return }
                            self.retryScheduledGeneration = nil
                            self.retryTask = nil
                        }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    try? await self?.resolveAndPlay(at: position)
                }
                return
            }
            throw error
        }

        guard requestGeneration == generation,
              requestedFile.fileId == currentFile.fileId,
              !Task.isCancelled else { throw CancellationError() }
        guard resource.url.scheme?.lowercased() == "https" else {
            throw QuarkError.unsupportedPlayback("仅允许 HTTPS 播放地址。")
        }
        var customHeaders = resource.requiredHTTPHeaders
        if customHeaders["User-Agent"] == nil {
            customHeaders["User-Agent"] = customHeaders.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 quark-cloud-drive/2.5.20"
        }
        if customHeaders["Referer"] == nil {
            customHeaders["Referer"] = "https://pan.quark.cn/"
        }
        if customHeaders["Origin"] == nil {
            customHeaders["Origin"] = "https://pan.quark.cn"
        }
        let applicableCookies = PlaybackProbe.applicableCookies(resource.cookies, url: resource.url)
        if !applicableCookies.isEmpty && customHeaders["Cookie"] == nil {
            let cookieHeader = applicableCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            customHeaders["Cookie"] = cookieHeader
        }

        // 统一收敛为 KSPlayer 单一引擎驱动
        KSOptions.firstPlayerType = KSMEPlayer.self
        // 配置音频渲染核心为 AudioRendererPlayer (AVSampleBufferAudioRenderer)
        // 解决 5.1/7.1 杜比音效在双声道扬声器上引发的 AVAudioEngine 崩溃无声，并原生支持空间音频与全景声输出
        KSOptions.audioPlayerType = AudioRendererPlayer.self

        let options = KSOptions()
        options.appendHeader(Self.headersExcludingCookie(customHeaders))
        options.setCookie(applicableCookies)
        options.preferredForwardBufferDuration = 60.0
        options.audioFilters = ["aresample=async=1"]

        detachObservers()

        self.ksPlayerOptions = options
        self.ksPlayerURL = resource.url
        self.ksAudioOptions = []
        self.ksSubtitleOptions = []
        self.ksSubtitleParts = []
        self.lastKSAudioIDs = []
        self.lastKSSubtitleIDs = []
        self.lastKSSelectedAudioIndex = nil
        self.lastKSSelectedSubtitleIndex = nil

        ksCoordinator.onPlay = { [weak self] current, duration in
            guard let self else { return }
            self.refreshKSOptions()
            if position > 0 && current < 1.0 {
                self.ksCoordinator.seek(time: position)
            }
            self.isPlaying = true
        }
        ksCoordinator.onStateChanged = { [weak self] _, state in
            guard let self else { return }
            switch state {
            case .buffering:
                self.isBuffering = true
                self.isPlaying = true
            case .readyToPlay, .bufferFinished:
                self.isBuffering = false
                self.isPlaying = true
            case .paused:
                self.isPlaying = false
            case .error:
                self.report(QuarkError.unsupportedPlayback("KSPlayer 解码播放异常，已为您记录诊断。"))
            default:
                break
            }
        }
        ksCoordinator.onBufferChanged = { [weak self] bufferedCount, consumeTime in
            guard let self else { return }
            if bufferedCount > 0 && consumeTime > 0 {
                let speedKB = Double(bufferedCount) / Double(consumeTime) / 1024.0
                if speedKB > 1024 {
                    self.networkSpeedText = String(format: "%.1f MB/s", speedKB / 1024.0)
                } else {
                    self.networkSpeedText = String(format: "%.0f KB/s", speedKB)
                }
            }
        }
        ksCoordinator.onFinish = { [weak self] _, error in
            guard let self else { return }
            if let error { self.handlePlaybackFailure(error) }
            else { self.playbackEnded() }
        }
        diagnostics.record("开始 KSPlayer (FFmpeg) 播放请求：\(requestedFile.name)")
    }

    private var safePlaybackTime: Double {
        let time = ksCoordinator.playerLayer?.player.currentPlaybackTime ?? 0
        return time.isFinite ? max(0, time) : 0
    }

    private var currentDiagnosticPlayerState: DiagnosticPlayerState {
        switch ksCoordinator.playerLayer?.player.playbackState {
        case .playing: return .playing
        case .paused: return .paused
        case .seeking, .idle: return .waiting
        case .finished: return .ended
        case .stopped: return .idle
        case .none: return .idle
        }
    }

    private func refreshKSOptions() {
        guard let ksPlayer = ksCoordinator.playerLayer?.player else { return }
        let audio = ksPlayer.tracks(mediaType: .audio)
        let subtitles = ksPlayer.tracks(mediaType: .subtitle)
        let selectedAudio = audio.firstIndex(where: { $0.isEnabled })
        let selectedSubtitle = subtitles.firstIndex(where: { $0.isEnabled })
        let audioChanged = Self.ksTrackSnapshotChanged(previousIDs: lastKSAudioIDs,
                                                       currentIDs: audio.map(\.trackID),
                                                       previousSelected: lastKSSelectedAudioIndex,
                                                       currentSelected: selectedAudio)
        let subtitleChanged = Self.ksTrackSnapshotChanged(previousIDs: lastKSSubtitleIDs,
                                                          currentIDs: subtitles.map(\.trackID),
                                                          previousSelected: lastKSSelectedSubtitleIndex,
                                                          currentSelected: selectedSubtitle)
        if audioChanged { ksAudioOptions = audio }
        if subtitleChanged { ksSubtitleOptions = subtitles }
        let parts = ksCoordinator.subtitleModel.parts
        if ksSubtitleParts != parts { ksSubtitleParts = parts }
        let infos = ksCoordinator.subtitleModel.subtitleInfos
        let modelSelectedSubtitle = Self.ksSubtitleSelectionIndex(
            infoIDs: infos.map(\.subtitleID),
            selectedID: ksCoordinator.subtitleModel.selectedSubtitleInfo?.subtitleID,
            trackFallback: selectedSubtitle
        )
        if selectedAudioIndex != selectedAudio { selectedAudioIndex = selectedAudio }
        if selectedSubtitleIndex != modelSelectedSubtitle { selectedSubtitleIndex = modelSelectedSubtitle }
        lastKSAudioIDs = audio.map(\.trackID)
        lastKSSubtitleIDs = subtitles.map(\.trackID)
        lastKSSelectedAudioIndex = selectedAudio
        lastKSSelectedSubtitleIndex = selectedSubtitle
        if audioChanged || subtitleChanged { recordAudioSnapshot(level: .info) }
    }

    private var currentAudioRoute: DiagnosticAudioRoute {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .unknown }
        if output.portType.rawValue.caseInsensitiveCompare("HDMI") == .orderedSame {
            return .hdmi
        }
        switch output.portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        case .airPlay: return .airPlay
        case .builtInSpeaker, .builtInReceiver: return .builtIn
        default: return .unknown
        }
    }

    private func recordPlaybackState(level: DiagnosticLevel, error: Error? = nil) {
        var metadata: [DiagnosticMetadata] = [
            .playbackTimeSeconds(safePlaybackTime),
            .playerState(currentDiagnosticPlayerState),
            .bufferEmpty(isBuffering),
            .likelyToKeepUp(!isBuffering),
            .route(currentAudioRoute)
        ]
        if let error { metadata.append(.errorCode((error as NSError).code)) }
        diagnostics.record(category: .playback, level: level, event: error == nil ? .playbackState : .playbackError, metadata: metadata)
    }

    private func recordAudioSnapshot(level: DiagnosticLevel) {
        var metadata: [DiagnosticMetadata] = [
            .trackCount(ksAudioOptions.count), .route(currentAudioRoute),
            .playbackTimeSeconds(safePlaybackTime)
        ]
        if let selectedAudioIndex { metadata.append(.audioTrackIndex(selectedAudioIndex)) }
        diagnostics.record(category: .audio, level: level, event: .audioSnapshot, metadata: metadata)
    }

    private func detachObservers() {
        ksCoordinator.resetPlayer()
        ksPlayerURL = nil
        ksPlayerOptions = nil
    }

    private func handlePlaybackFailure(_ error: Error) {
        saveProgress()
        guard Self.shouldScheduleRetry(currentGeneration: generation,
                                       scheduledGeneration: retryScheduledGeneration,
                                       retryTaskActive: retryTask != nil && !(retryTask?.isCancelled ?? true)) else { return }
        guard let delay = retryPolicy.delay(for: error, retriesUsed: retriesUsed) else {
            report(error)
            return
        }
        retriesUsed += 1
        retryScheduledGeneration = generation
        message = "播放中断，正在重新获取地址并重试（\(retriesUsed)/2）…"
        let retryGeneration = generation
        retryTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self, self.generation == retryGeneration else { return }
                    self.retryScheduledGeneration = nil
                    self.retryTask = nil
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                guard let self else { return }
                try await self.resolveAndPlay(at: self.retryPosition)
            } catch is CancellationError { return }
            catch {
                guard let self else { return }
                self.report(error)
            }
        }
    }

    private func playbackEnded() {
        saveProgress()
        if automaticallyPlayNext { playNext() }
        else if canPlayNext { message = "本集已播放完成，可选择播放下一集。" }
    }

    private func startRetryLoop() async {
        isLoading = true
        defer { isLoading = false }
        do { try await resolveAndPlay(at: retryPosition); message = nil }
        catch is CancellationError { return }
        catch { report(error) }
    }

    private var retryPosition: Double {
        if let value = ksCoordinator.playerLayer?.player.currentPlaybackTime,
           value.isFinite, value > 0 { return value }
        return restoredPosition
    }

    private func report(_ error: Error) {
        let safeMessage: String
        if let quarkError = error as? QuarkError { safeMessage = quarkError.localizedDescription }
        else if let urlError = error as? URLError { safeMessage = "网络播放错误（\(urlError.code.rawValue)）" }
        else { safeMessage = "播放失败（系统错误码 \((error as NSError).code)）" }
        message = safeMessage
        diagnostics.record(category: .playback, level: .error, event: .playbackError, metadata: [
            .playerState(.failed), .status(.failed), .errorCode((error as NSError).code)
        ])
    }
}
