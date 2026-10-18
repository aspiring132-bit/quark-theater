import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    static func shouldCommitSeek(operationToken: UUID, currentToken: UUID, playerMatches: Bool, isCancelled: Bool = false) -> Bool {
        !isCancelled && operationToken == currentToken && playerMatches
    }

    static func shouldClearSeekState(operationToken: UUID, currentToken: UUID, playerMatches: Bool, isCancelled: Bool) -> Bool {
        !isCancelled && operationToken == currentToken && playerMatches
    }

    static func shouldScheduleRetry(currentGeneration: Int, scheduledGeneration: Int?, retryTaskActive: Bool) -> Bool {
        !(retryTaskActive && scheduledGeneration == currentGeneration)
    }

    /// Returns true only when an observer callback still belongs to the active
    /// player and its active item. Queued AVFoundation callbacks can arrive
    /// after an item has been replaced, so checking the player alone is not
    /// sufficient for item-scoped state such as buffering and throughput.
    static func observerBelongsToCurrentPlayback(
        observedPlayer: AVPlayer,
        observedItem: AVPlayerItem,
        currentPlayer: AVPlayer?,
        currentItem: AVPlayerItem?
    ) -> Bool {
        observedPlayer === currentPlayer && observedItem === currentItem
    }

    @Published private(set) var player: AVPlayer?
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isBuffering = false
    @Published private(set) var networkSpeedText: String = ""
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    @Published private(set) var lastSilentMarkerDate: Date?
    private let client: QuarkClient
    private let accountID: String
    private var currentFile: CloudFile
    private let queue: [CloudFile]
    private let automaticallyPlayNext: Bool
    private let history: HistoryRepository
    private let diagnostics: Diagnostics
    private let retryPolicy = RetryPolicy(maximumRetries: 2, baseDelay: 1)
    private var periodicObserver: Any?
    private var speedObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var itemStatusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var retryTask: Task<Void, Never>?
    private var retryScheduledGeneration: Int?
    private var retriesUsed = 0
    private var restoredPosition: Double = 0
    private var generation = 0
    private var pendingSeekTarget: Double?
    private var inFlightSeekTarget: Double?
    private var seekTask: Task<Void, Never>?
    private var seekOperationToken = UUID()

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
        guard !isLoading, player == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            restoredPosition = try history.history(accountID: accountID, fileID: currentFile.fileId)?.positionSeconds ?? 0
            try await resolveAndPlay(at: restoredPosition)
        } catch is CancellationError { return }
        catch { report(error) }
    }

    func saveProgress() {
        guard let player else { return }
        let position = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        let duration = max(0, player.currentItem?.duration.seconds.isFinite == true ? player.currentItem!.duration.seconds : 0)
        let completed = duration > 0 && position >= duration * 0.95
        let record = WatchHistory(accountId: accountID, fileId: currentFile.fileId,
            fileName: currentFile.name,
            positionSeconds: completed ? duration : position, durationSeconds: duration,
            lastWatchedAt: Date(), completed: completed)
        do { try history.save(record) }
        catch { diagnostics.recordError(error, context: "播放进度保存") }
    }

    func retry() {
        retryTask?.cancel()
        retryScheduledGeneration = nil
        retriesUsed = 0
        retryTask = Task { await startRetryLoop() }
    }

    /// Handles one discrete Siri Remote skip. Invalid/unready player state is ignored.
    func seek(direction: PlayerSeekDirection, interval: Int) {
        guard let player, let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        guard let target = PlayerSeekMath.nextTarget(current: current, pending: pendingSeekTarget,
                                                     inFlight: inFlightSeekTarget,
                                                     direction: direction, interval: interval, duration: duration) else { return }
        pendingSeekTarget = target
        guard seekTask == nil else { return }
        let operationToken = UUID()
        seekOperationToken = operationToken
        seekTask = Task { @MainActor [weak self, weak player] in
            guard let self else { return }
            guard let player else {
                guard self.seekOperationToken == operationToken else { return }
                self.pendingSeekTarget = nil
                self.inFlightSeekTarget = nil
                self.seekTask = nil
                return
            }
            while let target = self.pendingSeekTarget {
                guard self.seekOperationToken == operationToken, self.player === player else { return }
                self.pendingSeekTarget = nil
                self.inFlightSeekTarget = target
                await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                guard Self.shouldCommitSeek(operationToken: operationToken, currentToken: self.seekOperationToken,
                                             playerMatches: self.player === player, isCancelled: Task.isCancelled) else {
                    guard Self.shouldClearSeekState(operationToken: operationToken,
                                                    currentToken: self.seekOperationToken,
                                                    playerMatches: self.player === player,
                                                    isCancelled: Task.isCancelled) else { return }
                    self.pendingSeekTarget = nil
                    self.inFlightSeekTarget = nil
                    self.seekTask = nil
                    return
                }
                self.inFlightSeekTarget = nil
                self.diagnostics.record(category: .playback, level: .debug, event: .playbackSeek,
                                        metadata: [.playbackTimeSeconds(target)])
            }
            guard self.seekOperationToken == operationToken else { return }
            self.inFlightSeekTarget = nil
            self.seekTask = nil
        }
    }

    @Published private(set) var selectedAudioIndex: Int?
    @Published private(set) var selectedSubtitleIndex: Int?

    var currentPlayingFile: CloudFile { currentFile }
    var playlistQueue: [CloudFile] { queue }

    func selectAudio(_ index: Int) {
        guard audioOptions.indices.contains(index), let audioGroup else { return }
        selectedAudioIndex = index
        player?.currentItem?.select(audioOptions[index], in: audioGroup)
        recordAudioSnapshot(level: .notice)
    }

    func selectSubtitle(_ index: Int?) {
        guard let subtitleGroup else { return }
        selectedSubtitleIndex = index
        if let index, subtitleOptions.indices.contains(index) {
            player?.currentItem?.select(subtitleOptions[index], in: subtitleGroup)
        } else {
            player?.currentItem?.select(nil, in: subtitleGroup)
        }
    }

    var canPlayNext: Bool {
        guard let index = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) else { return false }
        return queue.indices.contains(index + 1)
    }

    func playFile(_ targetFile: CloudFile) {
        guard targetFile.fileId != currentFile.fileId else { return }
        seekTask?.cancel()
        seekOperationToken = UUID()
        seekTask = nil
        pendingSeekTarget = nil
        inFlightSeekTarget = nil
        saveProgress()
        retryTask?.cancel()
        detachObservers()
        player?.pause()
        generation &+= 1
        currentFile = targetFile
        restoredPosition = 0
        retriesUsed = 0
        message = nil
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        retryTask = Task {
            do { try await resolveAndPlay(at: 0) }
            catch is CancellationError { return }
            catch { report(error) }
        }
    }

    func playNext() {
        guard let index = queue.firstIndex(where: { $0.fileId == currentFile.fileId }),
              queue.indices.contains(index + 1) else { return }
        playFile(queue[index + 1])
    }

    func stop() {
        generation &+= 1
        retryTask?.cancel()
        seekTask?.cancel()
        seekOperationToken = UUID()
        seekTask = nil
        pendingSeekTarget = nil
        inFlightSeekTarget = nil
        saveProgress()
        detachObservers()
        player?.pause()
        player = nil
    }

    /// Records a user-provided report that sound may be missing. This is not acoustic detection.
    func markSilent() {
        lastSilentMarkerDate = Date()
        var metadata: [DiagnosticMetadata] = [
            .playbackTimeSeconds(safePlaybackTime),
            .playerState(currentDiagnosticPlayerState),
            .bufferEmpty(player?.currentItem?.isPlaybackBufferEmpty ?? false),
            .likelyToKeepUp(player?.currentItem?.isPlaybackLikelyToKeepUp ?? false),
            .trackCount(audioOptions.count),
            .route(currentAudioRoute)
        ]
        if let selectedAudioIndex { metadata.append(.audioTrackIndex(selectedAudioIndex)) }
        if let waitingReason = currentWaitingReason { metadata.append(.waitingReason(waitingReason)) }
        diagnostics.record(category: .audio, level: .notice, event: .silentMarker, metadata: metadata)
        recordAccessAndErrorSummaries()
    }

    private func resolveAndPlay(at position: Double) async throws {
        let requestGeneration = generation
        let requestedFile = currentFile
        let resource = try await client.playbackResource(fileID: requestedFile.fileId)
        guard requestGeneration == generation, requestedFile.fileId == currentFile.fileId,
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

        let options: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: customHeaders["User-Agent"] ?? "",
            AVURLAssetHTTPCookiesKey: applicableCookies,
            "AVURLAssetHTTPHeaderFieldsKey": customHeaders
        ]
        let asset = AVURLAsset(url: resource.url, options: options)
        let item = AVPlayerItem(asset: asset)

        // Large file (e.g. 6GB 4K/1080P) streaming optimizations:
        // 1. Buffer up to 60 seconds ahead instead of default 2s to absorb CDN jitter
        item.preferredForwardBufferDuration = 60.0
        // 2. Allow continuous buffering while paused/stalled
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        // 3. Keep full original bitrate
        item.preferredPeakBitRate = 0

        let next = AVPlayer(playerItem: item)
        // 4. Strictly synchronize audio and video; wait for buffer instead of dropping video frames
        next.automaticallyWaitsToMinimizeStalling = true

        invalidateSeekState()
        detachObservers()
        attachProgressObserver(to: next)
        player?.pause()
        player = next
        audioOptions = []; subtitleOptions = []; audioGroup = nil; subtitleGroup = nil
        Task { await loadMediaOptions(asset: asset, for: item, generation: requestGeneration) }
        if position > 0 {
            // seek(to:) is async in tvOS 26+ SDK; dispatch to avoid blocking the calling context.
            Task { await next.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        }
        next.play()
        diagnostics.record(category: .playback, level: .info, event: .playbackState, metadata: [
            .playerState(.loading), .status(.started)
        ])
    }

    private func loadMediaOptions(asset: AVURLAsset, for item: AVPlayerItem, generation: Int) async {
        do {
            let audio = try await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
            guard generation == self.generation, player?.currentItem === item else { return }
            audioGroup = audio; subtitleGroup = subtitles
            audioOptions = audio?.options ?? []
            subtitleOptions = subtitles?.options ?? []
            if let audio, let currentAudio = item.currentMediaSelection.selectedMediaOption(in: audio) {
                selectedAudioIndex = audio.options.firstIndex(of: currentAudio)
            }
            if let subtitles, let currentSub = item.currentMediaSelection.selectedMediaOption(in: subtitles) {
                selectedSubtitleIndex = subtitles.options.firstIndex(of: currentSub)
            }
            recordAudioSnapshot(level: .info)
        } catch {
            if !(error is CancellationError) {
                diagnostics.record(category: .audio, level: .warning, event: .audioError, metadata: [
                    .status(.unavailable), .errorCode((error as NSError).code)
                ])
            }
        }
    }

    private func attachProgressObserver(to player: AVPlayer) {
        if let item = player.currentItem {
            itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed, let error = item.error else { return }
                Task { @MainActor in
                    guard self?.player?.currentItem === item else { return }
                    self?.recordPlaybackState(level: .error, error: error)
                    self?.handlePlaybackFailure(error)
                }
            }
            bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard self?.player?.currentItem === item else { return }
                    self?.isBuffering = item.isPlaybackBufferEmpty
                    self?.recordPlaybackState(level: item.isPlaybackBufferEmpty ? .notice : .debug)
                }
            }
        }
        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard self?.player === player else { return }
                self?.isBuffering = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                self?.recordPlaybackState(level: .debug)
            }
        }
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 15, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in Task { @MainActor in
            guard self?.player === player else { return }
            self?.saveProgress()
        } }
        // 1-second timer to sample real network throughput
        if let observedItem = player.currentItem {
            speedObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
            ) { [weak self] _ in Task { @MainActor in
                guard let self,
                      Self.observerBelongsToCurrentPlayback(
                        observedPlayer: player,
                        observedItem: observedItem,
                        currentPlayer: self.player,
                        currentItem: self.player?.currentItem
                      ) else { return }
                self.sampleThroughput(from: observedItem)
            } }
        }
        itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in
                    guard self?.player?.currentItem === player.currentItem else { return }
                    self?.handlePlaybackFailure(error ?? QuarkError.invalidResponse("播放失败"))
                }
            })
        itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard self?.player?.currentItem === item else { return }
                    self?.playbackEnded()
                }
            })
        itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
            object: player.currentItem, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard let self,
                          Self.observerBelongsToCurrentPlayback(
                            observedPlayer: player,
                            observedItem: item,
                            currentPlayer: self.player,
                            currentItem: self.player?.currentItem
                          ) else { return }
                    self.isBuffering = true
                    self.recordPlaybackState(level: .notice)
                    self.recordAccessAndErrorSummaries()
                }
            })
        itemObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: "AVPlayerItemMediaSelectionDidChangeNotification"),
            object: player.currentItem, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard let self,
                          Self.observerBelongsToCurrentPlayback(
                            observedPlayer: player,
                            observedItem: item,
                            currentPlayer: self.player,
                            currentItem: self.player?.currentItem
                          ) else { return }
                    self.recordAudioSnapshot(level: .debug)
                }
            })
        itemObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: "AVPlayerItemNewAccessLogEntryNotification"),
            object: player.currentItem, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard let self,
                          Self.observerBelongsToCurrentPlayback(
                            observedPlayer: player,
                            observedItem: item,
                            currentPlayer: self.player,
                            currentItem: self.player?.currentItem
                          ) else { return }
                    self.recordAccessAndErrorSummaries()
                }
            })
        itemObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: "AVPlayerItemNewErrorLogEntryNotification"),
            object: player.currentItem, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard let self,
                          Self.observerBelongsToCurrentPlayback(
                            observedPlayer: player,
                            observedItem: item,
                            currentPlayer: self.player,
                            currentItem: self.player?.currentItem
                          ) else { return }
                    self.recordAccessAndErrorSummaries()
                }
            })
    }

    private var safePlaybackTime: Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private var currentDiagnosticPlayerState: DiagnosticPlayerState {
        guard let player else { return .idle }
        if player.currentItem?.status == .failed { return .failed }
        switch player.timeControlStatus {
        case .playing: return .playing
        case .waitingToPlayAtSpecifiedRate: return .waiting
        case .paused: return player.currentItem == nil ? .idle : .paused
        @unknown default: return .idle
        }
    }

    private var currentWaitingReason: DiagnosticWaitingReason? {
        guard let reason = player?.reasonForWaitingToPlay else { return nil }
        switch reason {
        case .evaluatingBufferingRate: return .evaluatingBufferingRate
        case .toMinimizeStalls: return .toMinimizeStalls
        case .noItemToPlay: return .noItemToPlay
        default: return .unknown
        }
    }

    private var currentAudioRoute: DiagnosticAudioRoute {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .unknown }
        // tvOS exposes HDMI as a runtime port value but not as a compile-time
        // AVAudioSession.Port member in the tvOS 27 SDK.
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
            .bufferEmpty(player?.currentItem?.isPlaybackBufferEmpty ?? false),
            .likelyToKeepUp(player?.currentItem?.isPlaybackLikelyToKeepUp ?? false),
            .route(currentAudioRoute)
        ]
        if let waitingReason = currentWaitingReason { metadata.append(.waitingReason(waitingReason)) }
        if let error { metadata.append(.errorCode((error as NSError).code)) }
        diagnostics.record(category: .playback, level: level, event: error == nil ? .playbackState : .playbackError, metadata: metadata)
    }

    private func recordAudioSnapshot(level: DiagnosticLevel) {
        var metadata: [DiagnosticMetadata] = [
            .trackCount(audioOptions.count), .route(currentAudioRoute),
            .playbackTimeSeconds(safePlaybackTime)
        ]
        if let selectedAudioIndex { metadata.append(.audioTrackIndex(selectedAudioIndex)) }
        diagnostics.record(category: .audio, level: level, event: .audioSnapshot, metadata: metadata)
    }

    private func recordAccessAndErrorSummaries() {
        guard let item = player?.currentItem else { return }
        if let event = item.accessLog()?.events.last {
            diagnostics.record(category: .playback, level: .debug, event: .playbackState, metadata: [
                .durationMilliseconds(max(0, event.durationWatched * 1_000)), .status(.completed)
            ])
        }
        if let event = item.errorLog()?.events.last {
            diagnostics.record(category: .playback, level: .warning, event: .playbackError, metadata: [
                .status(.failed), .errorCode(event.errorStatusCode)
            ])
        }
    }

    private func sampleThroughput(from item: AVPlayerItem) {
        guard let event = item.accessLog()?.events.last, event.observedBitrate > 0 else {
            return
        }
        let bytesPerSec = event.observedBitrate / 8.0
        if bytesPerSec >= 1024 * 1024 {
            networkSpeedText = String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        } else if bytesPerSec >= 1024 {
            networkSpeedText = String(format: "%.0f KB/s", bytesPerSec / 1024)
        } else {
            networkSpeedText = String(format: "%.0f B/s", bytesPerSec)
        }
    }

    private func detachObservers() {
        if let periodicObserver, let player { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        if let speedObserver, let player { player.removeTimeObserver(speedObserver) }
        speedObserver = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        bufferEmptyObserver?.invalidate()
        bufferEmptyObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
    }

    private func invalidateSeekState() {
        seekTask?.cancel()
        seekOperationToken = UUID()
        seekTask = nil
        pendingSeekTarget = nil
        inFlightSeekTarget = nil
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
                try await self.resolveAndPlay(at: self.player?.currentTime().seconds ?? self.restoredPosition)
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
        do { try await resolveAndPlay(at: player?.currentTime().seconds ?? restoredPosition); message = nil }
        catch is CancellationError { return }
        catch { report(error) }
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
