import AVFoundation
import Combine
import Foundation
@preconcurrency import KSPlayer

enum PlaybackReplacementAction: Equatable {
    case pauseAndPlay
    case startNormally
}

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

    static func shouldEmitPlaybackHeartbeat(now: Date, lastSampleDate: Date?,
                                             state: DiagnosticPlayerState,
                                             lastState: DiagnosticPlayerState?,
                                             audioTrackChanged: Bool,
                                             audioRouteChanged: Bool) -> Bool {
        if state != lastState || audioTrackChanged || audioRouteChanged { return true }
        guard state == .playing else { return false }
        guard let lastSampleDate else { return true }
        return now.timeIntervalSince(lastSampleDate) >= 15
    }

    static func shouldKeepExistingPlaybackHeartbeat(isTaskActive: Bool) -> Bool {
        isTaskActive
    }

    static func shouldResetPlaybackHeartbeatForSessionTransition(hasActivePlayer: Bool) -> Bool {
        hasActivePlayer
    }

    static func shouldTreatKSFinishAsFailure(_ error: Error?) -> Bool { error != nil }

    static func headersExcludingCookie(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
    }

    /// The subtitle model must follow the same, already-validated resource
    /// URL as the player. Keeping this tiny policy helper makes the URL
    /// binding explicit and testable without reaching into KSPlayer internals.
    static func subtitleResourceURL(for resourceURL: URL) -> URL {
        resourceURL
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

    static func shouldAcceptPlaybackResource(requestGeneration: Int, currentGeneration: Int,
                                              requestedFileID: String, currentFileID: String,
                                              resourceFileID: String, isCancelled: Bool) -> Bool {
        !isCancelled && requestGeneration == currentGeneration &&
            requestedFileID == currentFileID && resourceFileID == requestedFileID
    }

    /// A pending episode must stop the previous player before its replacement
    /// resource is committed.  Keeping the old player running while the new
    /// URL is being resolved can leave its last video frame on screen while
    /// audio continues, which is the reported episode-switch freeze.
    static func shouldPausePlayerBeforeReplacement(hasActivePlayer: Bool, isNewFile: Bool) -> Bool {
        hasActivePlayer && isNewFile
    }

    static func isNewPlaybackFile(targetFileID: String, currentFileID: String,
                                   pendingFileID: String?) -> Bool {
        targetFileID != (pendingFileID ?? currentFileID)
    }

    static func replacementAction(hasActivePlayer: Bool, isNewFile: Bool) -> PlaybackReplacementAction {
        shouldPausePlayerBeforeReplacement(hasActivePlayer: hasActivePlayer, isNewFile: isNewFile)
            ? .pauseAndPlay : .startNormally
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
    @Published private(set) var pendingFile: CloudFile?
    /// True only after the current generation receives KSPlayer's onPlay callback.
    @Published private(set) var isCurrentPlaybackStarted = false
    /// Keeps the UI in a distinct loading/switching state between request and first frame.
    @Published private(set) var isPlaybackTransitionActive = false
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
    private var playbackCorrelationID: DiagnosticCorrelationID?
    private var startedPlaybackGeneration: Int?
    private var lastPlaybackDiagnosticSampleDate: Date?
    private var lastPlaybackDiagnosticState: DiagnosticPlayerState?
    private var lastDiagnosticAudioRoute: DiagnosticAudioRoute?
    private var playbackHeartbeatTask: Task<Void, Never>?
    private var audioRouteObserver: NSObjectProtocol?

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
        installAudioRouteObserver()
        playbackCorrelationID = diagnostics.makeCorrelationID()
        startedPlaybackGeneration = nil
        isLoading = true
        generation += 1
        let requestGeneration = generation
        isCurrentPlaybackStarted = false
        isPlaybackTransitionActive = true
        defer {
            // A later episode selection owns the loading indicator.
            if requestGeneration == generation { isLoading = false }
        }
        do {
            restoredPosition = try history.history(accountID: accountID, fileID: currentFile.fileId)?.positionSeconds ?? 0
            try await resolveAndPlay(file: currentFile, at: restoredPosition, requestGeneration: requestGeneration)
        } catch is CancellationError {
            if requestGeneration == generation {
                pendingFile = nil
                isPlaybackTransitionActive = false
                isCurrentPlaybackStarted = false
            }
        } catch {
            guard requestGeneration == generation else { return }
            pendingFile = nil
            isPlaybackTransitionActive = false
            isCurrentPlaybackStarted = false
            report(error)
        }
    }

    func stop() {
        stopPlaybackHeartbeat()
        removeAudioRouteObserver()
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        retryScheduledGeneration = nil
        pendingFile = nil
        saveProgress()
        detachObservers()
        ksPlayerURL = nil
        ksPlayerOptions = nil
        isPlaying = false
        isCurrentPlaybackStarted = false
        isPlaybackTransitionActive = false
    }

    var canPlayNext: Bool {
        guard let currentIndex = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) else { return false }
        return currentIndex + 1 < queue.count
    }

    func playNext() {
        playNext(manualSelection: false)
    }

    func playNext(manualSelection: Bool) {
        guard let currentIndex = queue.firstIndex(where: { $0.fileId == currentFile.fileId }),
              currentIndex + 1 < queue.count else { return }
        let nextIndex = currentIndex + 1
        playFile(queue[nextIndex], selectionOrdinal: manualSelection ? nextIndex : nil)
    }

    @discardableResult
    func playFile(
        _ file: CloudFile,
        selectionOrdinal: Int? = nil,
        episodeNumber: Int? = nil
    ) -> Task<Void, Never> {
        saveProgress()
        let isNewFile = Self.isNewPlaybackFile(targetFileID: file.fileId,
                                               currentFileID: currentFile.fileId,
                                               pendingFileID: pendingFile?.fileId)
        if Self.shouldPausePlayerBeforeReplacement(hasActivePlayer: hasActivePlayer, isNewFile: isNewFile) {
            clearReplacementCallbacks()
            ksCoordinator.playerLayer?.pause()
            isPlaying = false
            isBuffering = false
            networkSpeedText = ""
        }
        if Self.shouldResetPlaybackHeartbeatForSessionTransition(hasActivePlayer: hasActivePlayer) {
            stopPlaybackHeartbeat()
        }
        pendingFile = file
        isCurrentPlaybackStarted = false
        isPlaybackTransitionActive = true
        restoredPosition = (try? history.history(accountID: accountID, fileID: file.fileId)?.positionSeconds) ?? 0
        message = nil
        retriesUsed = 0
        retryScheduledGeneration = nil
        retryTask?.cancel()
        retryTask = nil
        generation += 1
        let requestGeneration = generation
        playbackCorrelationID = diagnostics.makeCorrelationID()
        startedPlaybackGeneration = nil
        if let selectionOrdinal {
            var metadata: [DiagnosticMetadata] = [
                .episodeOrdinal(selectionOrdinal),
                .switchGeneration(requestGeneration)
            ]
            if let episodeNumber { metadata.append(.episodeNumber(episodeNumber)) }
            diagnostics.record(
                category: .playback,
                level: .info,
                event: .episodeSelectionRequested,
                correlationID: playbackCorrelationID,
                metadata: metadata
            )
        }
        return Task {
            isLoading = true
            defer {
                if self.generation == requestGeneration { self.isLoading = false }
            }
            do { try await resolveAndPlay(file: file, at: restoredPosition, requestGeneration: requestGeneration) }
            catch is CancellationError {
                if self.generation == requestGeneration {
                    self.pendingFile = nil
                    self.isPlaybackTransitionActive = false
                }
            }
            catch {
                guard self.generation == requestGeneration else { return }
                self.pendingFile = nil
                self.isPlaybackTransitionActive = false
                self.isCurrentPlaybackStarted = false
                report(error)
            }
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
                           correlationID: playbackCorrelationID,
                           metadata: [.playbackTimeSeconds(target)])
    }

    var currentPlayingFile: CloudFile { currentFile }
    var playlistQueue: [CloudFile] { queue }
    var playbackCorrelation: DiagnosticCorrelationID? { playbackCorrelationID }

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
        var metadata: [DiagnosticMetadata] = [.route(currentAudioRoute), .playbackTimeSeconds(safePlaybackTime)]
        if let selectedAudioIndex { metadata.append(.audioTrackIndex(selectedAudioIndex)) }
        diagnostics.record(category: .audio, level: .notice, event: .silentMarker,
                           correlationID: playbackCorrelationID, metadata: metadata)
    }

    private func resolveAndPlay(file: CloudFile, at position: Double, requestGeneration: Int) async throws {
        let requestedFile = file
        message = nil
        let resource: PlaybackResource
        do {
            resource = try await client.playbackResource(fileID: requestedFile.id,
                                                         correlationID: playbackCorrelationID)
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
                    do {
                        guard let self else { return }
                        try await self.resolveAndPlay(file: requestedFile, at: position, requestGeneration: retryGen)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard let self, self.generation == retryGen else { return }
                        self.pendingFile = nil
                        self.isPlaybackTransitionActive = false
                        self.isCurrentPlaybackStarted = false
                        self.report(error)
                    }
                }
                return
            }
            throw error
        }

        guard Self.shouldAcceptPlaybackResource(
            requestGeneration: requestGeneration,
            currentGeneration: generation,
            requestedFileID: requestedFile.fileId,
            currentFileID: pendingFile?.fileId ?? currentFile.fileId,
            resourceFileID: resource.fileID,
            isCancelled: Task.isCancelled
        ) else { throw CancellationError() }
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

        // KSPlayer 引擎配置：首选原生硬件 KSAVPlayer，遇复杂容器/编码自动无缝回落 KSMEPlayer (FFmpeg)
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isSecondOpen = true
        // 配置音频渲染核心为 AudioRendererPlayer (AVSampleBufferAudioRenderer)
        // 解决 5.1/7.1 杜比音效在双声道扬声器上引发的 AVAudioEngine 崩溃无声，并原生支持空间音频与全景声输出
        KSOptions.audioPlayerType = AudioRendererPlayer.self

        let options = KSOptions()
        options.appendHeader(Self.headersExcludingCookie(customHeaders))
        options.setCookie(applicableCookies)
        options.preferredForwardBufferDuration = 3.0
        options.maxBufferDuration = 60.0

        currentFile = requestedFile
        pendingFile = nil

        self.ksPlayerOptions = options
        self.ksPlayerURL = resource.url
        // Replacing a KSPlayer URL does not automatically replace the
        // subtitle model. Bind it to the verified resource so stale subtitle
        // entries from the previous episode are cleared and re-discovered.
        ksCoordinator.subtitleModel.url = Self.subtitleResourceURL(for: resource.url)
        self.ksAudioOptions = []
        self.ksSubtitleOptions = []
        self.ksSubtitleParts = []
        self.lastKSAudioIDs = []
        self.lastKSSubtitleIDs = []
        self.lastKSSelectedAudioIndex = nil
        self.lastKSSelectedSubtitleIndex = nil

        // Register callbacks FIRST so that any lifecycle or readiness transition
        // triggered by playerLayer.set(url:options:) or initial play() is reliably captured.
        ksCoordinator.onPlay = { [weak self] current, duration in
            guard let self else { return }
            guard self.generation == requestGeneration, self.currentFile.fileId == requestedFile.fileId else { return }
            self.refreshKSOptions()
            self.startPlaybackHeartbeat()
            if position > 0 && current < 1.0 {
                self.ksCoordinator.seek(time: position)
            }
            self.isPlaying = true
            self.isCurrentPlaybackStarted = true
            self.isPlaybackTransitionActive = false
            guard self.startedPlaybackGeneration != requestGeneration else { return }
            self.startedPlaybackGeneration = requestGeneration
            var startedMetadata: [DiagnosticMetadata] = [
                .endpoint(.filePlay), .playerEngine(.unknown), .switchGeneration(requestGeneration)
            ]
            if let ordinal = self.queue.firstIndex(where: { $0.fileId == requestedFile.fileId }) {
                startedMetadata.append(.episodeOrdinal(ordinal))
            }
            self.diagnostics.record(
                category: .playback,
                level: .info,
                event: .started,
                correlationID: self.playbackCorrelationID,
                metadata: startedMetadata
            )
        }
        ksCoordinator.onStateChanged = { [weak self] _, state in
            guard let self else { return }
            guard self.generation == requestGeneration, self.currentFile.fileId == requestedFile.fileId else { return }
            switch state {
            case .buffering:
                self.isBuffering = true
                self.isPlaying = true
            case .readyToPlay, .bufferFinished:
                self.isBuffering = false
                self.isPlaying = true
            case .paused:
                self.isPlaying = false
                self.stopPlaybackHeartbeat()
            case .playedToTheEnd:
                self.isPlaying = false
                self.stopPlaybackHeartbeat()
            case .error:
                self.report(QuarkError.unsupportedPlayback("KSPlayer 解码播放异常，已为您记录诊断。"))
            default:
                break
            }

            if state == .readyToPlay {
                let player = self.ksCoordinator.playerLayer?.player
                let hasAudio = !(player?.tracks(mediaType: .audio).isEmpty ?? true)
                let hasVideo = !(player?.tracks(mediaType: .video).isEmpty ?? true)
                let size = player?.naturalSize ?? .zero
                let hasNaturalSize = size.width > 0 && size.height > 0
                var readinessMetadata: [DiagnosticMetadata] = [
                    .switchGeneration(requestGeneration),
                    .playerState(.readyToPlay),
                    .audioTrackPresent(hasAudio),
                    .videoTrackPresent(hasVideo),
                    .videoNaturalSizeAvailable(hasNaturalSize)
                ]
                if let ordinal = self.queue.firstIndex(where: { $0.fileId == requestedFile.fileId }) {
                    readinessMetadata.append(.episodeOrdinal(ordinal))
                }
                self.diagnostics.record(
                    category: .playback,
                    level: .info,
                    event: .playerReadiness,
                    correlationID: self.playbackCorrelationID,
                    metadata: readinessMetadata
                )
            }

            self.recordPlaybackState(level: .debug)
        }
        ksCoordinator.onBufferChanged = { [weak self] bufferedCount, consumeTime in
            guard let self else { return }
            guard self.generation == requestGeneration, self.currentFile.fileId == requestedFile.fileId else { return }
            if bufferedCount == 0 {
                let player = self.ksCoordinator.playerLayer?.player
                let hasAudio = !(player?.tracks(mediaType: .audio).isEmpty ?? true)
                let hasVideo = !(player?.tracks(mediaType: .video).isEmpty ?? true)
                let size = player?.naturalSize ?? .zero
                let hasNaturalSize = size.width > 0 && size.height > 0
                var firstBufferMetadata: [DiagnosticMetadata] = [
                    .switchGeneration(requestGeneration),
                    .firstBufferReady(true),
                    .audioTrackPresent(hasAudio),
                    .videoTrackPresent(hasVideo),
                    .videoNaturalSizeAvailable(hasNaturalSize)
                ]
                if let ordinal = self.queue.firstIndex(where: { $0.fileId == requestedFile.fileId }) {
                    firstBufferMetadata.append(.episodeOrdinal(ordinal))
                }
                self.diagnostics.record(
                    category: .playback,
                    level: .info,
                    event: .firstBufferReady,
                    correlationID: self.playbackCorrelationID,
                    metadata: firstBufferMetadata
                )
            }
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
            guard self.generation == requestGeneration, self.currentFile.fileId == requestedFile.fileId else { return }
            if let error { self.handlePlaybackFailure(error) }
            else { self.playbackEnded() }
        }

        // Callbacks are fully registered; initiate resource replacement on the mounted playerLayer.
        if let playerLayer = ksCoordinator.playerLayer {
            playerLayer.set(url: resource.url, options: options)
            playerLayer.play()
        }
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
        let previousRoute = lastDiagnosticAudioRoute
        let currentRoute = currentAudioRoute
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
        if audioChanged || subtitleChanged || previousRoute != currentRoute {
            recordAudioSnapshot(level: .info)
        }
        lastDiagnosticAudioRoute = currentRoute
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
        let state = currentDiagnosticPlayerState
        let now = Date()
        if level == .debug,
           let last = lastPlaybackDiagnosticSampleDate,
           now.timeIntervalSince(last) < 1,
           lastPlaybackDiagnosticState == state {
            return
        }
        lastPlaybackDiagnosticSampleDate = now
        lastPlaybackDiagnosticState = state
        var metadata: [DiagnosticMetadata] = [
            .playbackTimeSeconds(safePlaybackTime),
            .playerState(state),
            .bufferEmpty(isBuffering),
            .likelyToKeepUp(!isBuffering),
            .route(currentAudioRoute)
        ]
        if let player = ksCoordinator.playerLayer?.player {
            let engine = Self.diagnosticEngine(for: String(describing: type(of: player)))
            metadata.append(.playerEngine(engine))
            if let info = player.dynamicInfo {
                // KSPlayer exposes this delta in seconds; diagnostics use ms.
                metadata.append(.avSyncDeltaMilliseconds(info.audioVideoSyncDiff * 1000))
                metadata.append(.droppedFrames(Int(info.droppedVideoFrameCount + info.droppedVideoPacketCount)))
            }
        }
        if let ordinal = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) {
            metadata.append(.episodeOrdinal(ordinal))
        }
        if let error { metadata.append(.errorCode((error as NSError).code)) }
        diagnostics.record(category: .playback, level: level, event: error == nil ? .playbackState : .playbackError,
                           correlationID: playbackCorrelationID, metadata: metadata)
    }

    private static func diagnosticEngine(for typeName: String) -> DiagnosticPlayerEngine {
        if typeName.contains("KSAVPlayer") { return .ksAVPlayer }
        if typeName.contains("KSMEPlayer") { return .ksMEPlayer }
        return .unknown
    }

    private func recordAudioSnapshot(level: DiagnosticLevel) {
        var metadata: [DiagnosticMetadata] = [
            .trackCount(ksAudioOptions.count), .route(currentAudioRoute),
            .playbackTimeSeconds(safePlaybackTime)
        ]
        if let selectedAudioIndex { metadata.append(.audioTrackIndex(selectedAudioIndex)) }
        diagnostics.record(category: .audio, level: level, event: .audioSnapshot,
                           correlationID: playbackCorrelationID, metadata: metadata)
    }

    private func detachObservers() {
        ksCoordinator.resetPlayer()
        ksPlayerURL = nil
        ksPlayerOptions = nil
    }

    private func startPlaybackHeartbeat() {
        let isTaskActive = playbackHeartbeatTask.map { !$0.isCancelled } ?? false
        guard !Self.shouldKeepExistingPlaybackHeartbeat(isTaskActive: isTaskActive) else { return }
        playbackHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard Self.shouldEmitPlaybackHeartbeat(
                    now: Date(), lastSampleDate: self.lastPlaybackDiagnosticSampleDate,
                    state: self.currentDiagnosticPlayerState,
                    lastState: self.lastPlaybackDiagnosticState,
                    audioTrackChanged: false,
                    audioRouteChanged: false
                ) else { continue }
                self.recordPlaybackState(level: .debug)
            }
        }
    }

    private func stopPlaybackHeartbeat() {
        playbackHeartbeatTask?.cancel()
        playbackHeartbeatTask = nil
    }

    private func installAudioRouteObserver() {
        guard audioRouteObserver == nil else { return }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshKSOptions()
                self.recordPlaybackState(level: .notice)
            }
        }
    }

    private func removeAudioRouteObserver() {
        if let audioRouteObserver {
            NotificationCenter.default.removeObserver(audioRouteObserver)
            self.audioRouteObserver = nil
        }
    }

    /// Clears callbacks before replacing the URL, but preserves the mounted
    /// KSPlayerLayer so KSPlayer can perform its supported in-place replacement.
    private func clearReplacementCallbacks() {
        ksCoordinator.onPlay = nil
        ksCoordinator.onStateChanged = nil
        ksCoordinator.onBufferChanged = nil
        ksCoordinator.onFinish = nil
    }

    private func handlePlaybackFailure(_ error: Error) {
        saveProgress()
        guard Self.shouldScheduleRetry(currentGeneration: generation,
                                       scheduledGeneration: retryScheduledGeneration,
                                       retryTaskActive: retryTask != nil && !(retryTask?.isCancelled ?? true)) else { return }
        guard let delay = retryPolicy.delay(for: error, retriesUsed: retriesUsed) else {
            pendingFile = nil
            isPlaybackTransitionActive = false
            isCurrentPlaybackStarted = false
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
                try await self.resolveAndPlay(file: self.pendingFile ?? self.currentFile,
                                              at: self.retryPosition, requestGeneration: retryGeneration)
            } catch is CancellationError { return }
            catch {
                guard let self, self.generation == retryGeneration else { return }
                self.pendingFile = nil
                self.isPlaybackTransitionActive = false
                self.isCurrentPlaybackStarted = false
                self.report(error)
            }
        }
    }

    private func playbackEnded() {
        saveProgress()
        diagnostics.record(category: .playback, level: .info, event: .playbackState,
                           correlationID: playbackCorrelationID,
                           metadata: [.playerState(.ended), .playbackTimeSeconds(safePlaybackTime)])
        if automaticallyPlayNext { playNext() }
        else if canPlayNext { message = "本集已播放完成，可选择播放下一集。" }
    }

    private func startRetryLoop() async {
        isLoading = true
        defer { isLoading = false }
        generation += 1
        let requestGeneration = generation
        do {
            try await resolveAndPlay(file: pendingFile ?? currentFile, at: retryPosition,
                                     requestGeneration: requestGeneration)
            message = nil
        }
        catch is CancellationError {
            if requestGeneration == generation {
                pendingFile = nil
                isPlaybackTransitionActive = false
                isCurrentPlaybackStarted = false
            }
        }
        catch {
            guard requestGeneration == generation else { return }
            pendingFile = nil
            isPlaybackTransitionActive = false
            isCurrentPlaybackStarted = false
            report(error)
        }
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
        diagnostics.record(category: .playback, level: .error, event: .playbackError,
                           correlationID: playbackCorrelationID, metadata: [
            .playerState(.failed), .status(.failed), .errorCode((error as NSError).code)
        ])
    }
}
