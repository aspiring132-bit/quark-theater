import AVFoundation
import Combine
import Foundation
import UIKit

enum PlaybackReplacementAction: Equatable {
    case pauseAndPlay
    case startNormally
}

enum IntroSkipStatus: Equatable {
    case idle
    case pending(target: Double)
    case failed(message: String)
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var message: String?
    @Published private(set) var isResolvingResource: Bool = false
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var networkSpeedText: String = ""
    @Published private(set) var audioTracks: [PlaybackTrack] = []
    @Published private(set) var subtitleTracks: [PlaybackTrack] = []
    @Published private(set) var selectedAudioIndex: Int?
    @Published private(set) var selectedSubtitleIndex: Int?
    @Published private(set) var lastSilentMarkerDate: Date?
    @Published private(set) var isCurrentPlaybackStarted: Bool = false
    @Published private(set) var isPlaybackTransitionActive: Bool = false
    @Published private(set) var pendingFile: CloudFile?
    @Published private(set) var activePlayingFileID: String?
    @Published private(set) var currentEpisodeMarkers: ResolvedEpisodeMarkers = .empty
    @Published private(set) var snapshot: PlaybackSnapshot = .idle()
    @Published private(set) var introSkipStatus: IntroSkipStatus = .idle

    private let client: QuarkClient
    private let accountID: String
    @Published private(set) var committedActiveFile: CloudFile
    private var currentFile: CloudFile {
        get { committedActiveFile }
        set { committedActiveFile = newValue }
    }
    private let queue: [CloudFile]
    private let automaticallyPlayNext: Bool
    private let history: HistoryRepository
    private let diagnostics: Diagnostics
    private let sourceRepository: SourceRepository
    private let engine: PlaybackEngine
    private let retryPolicy = RetryPolicy(maximumRetries: 2, baseDelay: 1)
    private var retryTask: Task<Void, Never>?
    private var retryScheduledGeneration: Int?
    private var retriesUsed = 0
    private var restoredPosition: Double = 0
    private var pendingRestoration: (generation: Int, position: Double)?
    private(set) var generation = 0
    private var playbackCorrelationID: DiagnosticCorrelationID?
    private var startedPlaybackGeneration: Int?
    private var audioRouteObserver: NSObjectProtocol?
    private var silentMarkerFollowUpTask: Task<Void, Never>?
    private var markerResolutionTask: Task<Void, Never>?
    private var markerResolutionTriggeredGeneration: Int?
    private var introSkipTask: Task<Void, Never>?
    private var snapshotPollTask: Task<Void, Never>?
    private var activeResource: PlaybackResource?
    private var bufferingPolicy = PlaybackBufferingPolicy()
    private var bufferingPolicyState: PlaybackBufferingPolicy.State?

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

    static func headersExcludingCookie(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
    }

    static func subtitleResourceURL(for resourceURL: URL) -> URL {
        resourceURL
    }

    static func isPlaybackURLAllowed(_ url: URL, allowLocalUITestFile: Bool) -> Bool {
        url.scheme?.lowercased() == "https" || (allowLocalUITestFile && url.isFileURL)
    }

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

    var hasActivePlayer: Bool {
        activeResource != nil && engine.snapshot.state != .idle
    }

    var currentPlayingFile: CloudFile { committedActiveFile }
    var committedActiveFileID: String { activePlayingFileID ?? committedActiveFile.fileId }

    func isEpisodePlaying(fileID: String) -> Bool {
        fileID == committedActiveFileID && fileID != pendingFile?.fileId
    }

    func isEpisodePending(fileID: String) -> Bool {
        fileID == pendingFile?.fileId
    }

    static func introSkipTarget(introEndSeconds: Double, duration: Double) -> Double {
        max(0, min(introEndSeconds + 1.0, duration))
    }

    var playlistQueue: [CloudFile] { queue }
    var playbackCorrelation: DiagnosticCorrelationID? { playbackCorrelationID }
    private(set) var lastRequestedPlaybackFileID: String?

    var ksPlayerURL: URL? {
        activeResource?.url
    }

    var isLoading: Bool {
        isResolvingResource || snapshot.state == .loading
    }

    var playbackTime: Double {
        let time = snapshot.currentTime
        return (time.isFinite && time >= 0) ? time : 0
    }

    var playbackDuration: Double {
        let duration = snapshot.duration
        return (duration.isFinite && duration >= 0) ? duration : 0
    }

    var bufferedTime: Double {
        let time = snapshot.bufferedTime
        return (time.isFinite && time >= 0) ? time : 0
    }

    var bufferedRanges: [PlaybackTimeRange] {
        snapshot.bufferedRanges
    }

    var audioTrackNames: [String] {
        audioTracks.enumerated().map { index, track in
            track.name.isEmpty ? "音轨 \(index + 1)" : track.name
        }
    }

    var subtitleTrackNames: [String] {
        subtitleTracks.filter { !$0.isDisabled }.enumerated().map { index, track in
            track.name.isEmpty ? "字幕 \(index + 1)" : track.name
        }
    }

    init(client: QuarkClient, accountID: String, file: CloudFile, queue: [CloudFile] = [],
         automaticallyPlayNext: Bool = false, history: HistoryRepository, diagnostics: Diagnostics,
         sourceRepository: SourceRepository = .shared,
         engine: PlaybackEngine? = nil) {
        self.client = client
        self.accountID = accountID
        self.committedActiveFile = file
        self.queue = queue.isEmpty ? [file] : queue
        self.automaticallyPlayNext = automaticallyPlayNext
        self.history = history
        self.diagnostics = diagnostics
        self.sourceRepository = sourceRepository
        let resolvedEngine = engine ?? VLCPlaybackController(diagnostics: diagnostics)
        self.engine = resolvedEngine
        self.engine.eventHandler = { [weak self] event in
            self?.handleEngineEvent(event)
        }
    }

    func attachSurface(_ surface: UIView?) {
        engine.attachSurface(surface)
    }

    func start() async {
        guard !isResolvingResource, !hasActivePlayer else { return }
        markerResolutionTask?.cancel()
        markerResolutionTask = nil
        currentEpisodeMarkers = .empty
        markerResolutionTriggeredGeneration = nil
        installAudioRouteObserver()
        playbackCorrelationID = diagnostics.makeCorrelationID()
        startedPlaybackGeneration = nil
        isResolvingResource = true
        generation += 1
        let requestGeneration = generation
        bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
        isCurrentPlaybackStarted = false
        isPlaybackTransitionActive = true
        var selectionMetadata: [DiagnosticMetadata] = [.switchGeneration(requestGeneration)]
        if let ordinal = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) {
            selectionMetadata.append(.episodeOrdinal(ordinal))
        }
        diagnostics.record(
            category: .playback,
            level: .info,
            event: .episodeSelectionRequested,
            correlationID: playbackCorrelationID,
            metadata: selectionMetadata
        )
        defer {
            if requestGeneration == generation { isResolvingResource = false }
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
        stopSnapshotPolling()
        silentMarkerFollowUpTask?.cancel()
        silentMarkerFollowUpTask = nil
        removeAudioRouteObserver()
        generation += 1
        bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
        retryTask?.cancel()
        retryTask = nil
        retryScheduledGeneration = nil
        pendingFile = nil
        pendingRestoration = nil
        saveProgress()
        markerResolutionTask?.cancel()
        markerResolutionTask = nil
        markerResolutionTriggeredGeneration = nil
        introSkipTask?.cancel()
        introSkipTask = nil
        introSkipStatus = .idle
        currentEpisodeMarkers = .empty
        activeResource = nil
        engine.stop()
        isPlaying = false
        isBuffering = false
        isResolvingResource = false
        activePlayingFileID = nil
        isCurrentPlaybackStarted = false
        isPlaybackTransitionActive = false
        snapshot = .idle(generation: generation)
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
        if isNewFile {
            markerResolutionTask?.cancel()
            markerResolutionTask = nil
            currentEpisodeMarkers = .empty
            markerResolutionTriggeredGeneration = nil
            introSkipTask?.cancel()
            introSkipTask = nil
            introSkipStatus = .idle
        }
        if Self.shouldPausePlayerBeforeReplacement(hasActivePlayer: hasActivePlayer, isNewFile: isNewFile) {
            engine.pause()
            isPlaying = false
            isBuffering = false
            bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation + 1)
            networkSpeedText = ""
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
        bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
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
        return Task { @MainActor [weak self] in
            guard let self else { return }
            self.isResolvingResource = true
            defer {
                if self.generation == requestGeneration { self.isResolvingResource = false }
            }
            do {
                try await self.resolveAndPlay(file: file, at: self.restoredPosition, requestGeneration: requestGeneration)
            } catch is CancellationError {
                if self.generation == requestGeneration {
                    self.pendingFile = nil
                    self.isPlaybackTransitionActive = false
                }
            } catch {
                guard self.generation == requestGeneration else { return }
                self.pendingFile = nil
                self.isPlaybackTransitionActive = false
                self.isCurrentPlaybackStarted = false
                self.report(error)
            }
        }
    }

    func saveProgress() {
        let position = playbackTime
        let duration = playbackDuration
        guard position > 5, duration > 10 else { return }
        let completed = duration > 0 && position >= duration * 0.95
        let record = WatchHistory(
            accountId: accountID,
            fileId: currentFile.fileId,
            fileName: currentFile.name,
            positionSeconds: completed ? duration : position,
            durationSeconds: duration,
            lastWatchedAt: Date(),
            completed: completed
        )
        do {
            try history.save(record)
        } catch {
            diagnostics.recordError(error, context: "播放进度保存")
        }
    }

    func togglePlayPause() {
        if isPlaying {
            engine.pause()
            isPlaying = false
            bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
        } else {
            engine.play()
            isPlaying = true
        }
        recordAudioSnapshot(level: .debug)
    }

    func retry() {
        retryTask?.cancel()
        retryScheduledGeneration = nil
        retriesUsed = 0
        retryTask = Task { @MainActor [weak self] in
            await self?.startRetryLoop()
        }
    }

    func seek(direction: PlayerSeekDirection, interval: Int) {
        bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
        let current = playbackTime
        let duration = playbackDuration
        let baseInterval: Int
        if interval > 15, interval.isMultiple(of: 15) {
            baseInterval = 15
        } else {
            baseInterval = PlayerSeekMath.normalizedInterval(interval)
        }
        let steps = max(1, Int(ceil(Double(max(interval, baseInterval)) / Double(baseInterval))))
        var target = current
        for _ in 0..<steps {
            guard let next = PlayerSeekMath.target(current: target, direction: direction,
                                                   interval: baseInterval, duration: duration) else { return }
            target = next
        }
        engine.seek(to: target)
        diagnostics.record(
            category: .playback,
            level: .debug,
            event: .playbackSeek,
            correlationID: playbackCorrelationID,
            metadata: [.playbackTimeSeconds(target), .playerEngine(.vlcPlayer)]
        )
    }

    @discardableResult
    func seek(to seconds: Double, recordDiagnostics: Bool = true) -> Bool {
        bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
        let duration = playbackDuration
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let accepted = engine.seek(to: target)
        if recordDiagnostics {
            diagnostics.record(
                category: .playback,
                level: .debug,
                event: .playbackSeek,
                correlationID: playbackCorrelationID,
                metadata: [.playbackTimeSeconds(target), .playerEngine(.vlcPlayer)]
            )
        }
        return accepted
    }

    @discardableResult
    func skipIntro() -> Bool {
        guard let intro = currentEpisodeMarkers.intro, playbackDuration > 0 else { return false }
        if case .pending = introSkipStatus { return false }
        let duration = playbackDuration
        let target = Self.introSkipTarget(introEndSeconds: intro.endSeconds, duration: duration)

        introSkipTask?.cancel()
        introSkipStatus = .pending(target: target)

        // Single action-level diagnostic log for the user action
        diagnostics.record(
            category: .playback,
            level: .info,
            event: .playbackSeek,
            correlationID: playbackCorrelationID,
            metadata: [.playbackTimeSeconds(target), .playerEngine(.vlcPlayer)]
        )

        let initialAccepted = seek(to: target, recordDiagnostics: false)
        let expectedGeneration = generation

        introSkipTask = Task { @MainActor [weak self] in
            let maxAttempts = 3
            var attempt = 1
            var accepted = initialAccepted
            while !accepted && attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.generation == expectedGeneration, !Task.isCancelled else { return }
                attempt += 1
                accepted = self.seek(to: target, recordDiagnostics: false)
            }

            if !accepted {
                guard let self, self.generation == expectedGeneration, !Task.isCancelled else { return }
                self.introSkipStatus = .failed(message: "跳过失败，点击重试")
                return
            }

            let pollDeadline = Date().addingTimeInterval(2.5)
            while Date() < pollDeadline {
                guard let self, self.generation == expectedGeneration, !Task.isCancelled else { return }
                if self.playbackTime >= min(intro.endSeconds, self.playbackDuration) {
                    self.introSkipStatus = .idle
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard let self, self.generation == expectedGeneration, !Task.isCancelled else { return }
            if self.playbackTime < min(intro.endSeconds, self.playbackDuration) {
                self.introSkipStatus = .failed(message: "跳过超时，点击重试")
            } else {
                self.introSkipStatus = .idle
            }
        }
        return true
    }

    func setMarkersForTesting(_ markers: ResolvedEpisodeMarkers, duration: Double) {
        currentEpisodeMarkers = markers
        snapshot = PlaybackSnapshot(
            generation: generation,
            state: .playing,
            currentTime: snapshot.currentTime,
            duration: duration,
            bufferedTime: snapshot.bufferedTime,
            networkRate: snapshot.networkRate,
            hasVideoOutput: snapshot.hasVideoOutput,
            bufferedRanges: snapshot.bufferedRanges
        )
    }

    func selectAudio(_ index: Int) {
        guard audioTracks.indices.contains(index) else { return }
        let track = audioTracks[index]
        engine.selectAudioTrack(id: track.id)
        selectedAudioIndex = index
        recordAudioSnapshot(level: .notice)
    }

    func selectSubtitle(_ index: Int?) {
        let selectable = subtitleTracks.filter { !$0.isDisabled }
        if let index, selectable.indices.contains(index) {
            let track = selectable[index]
            engine.selectSubtitleTrack(id: track.id)
            selectedSubtitleIndex = index
        } else {
            engine.selectSubtitleTrack(id: nil)
            selectedSubtitleIndex = nil
        }
    }

    func markSilent() {
        let now = Date()
        lastSilentMarkerDate = now
        recordAudioSnapshot(level: .notice)
        var metadata: [DiagnosticMetadata] = [
            .route(currentAudioRoute),
            .playbackTimeSeconds(playbackTime),
            .playerEngine(.vlcPlayer)
        ]
        if let selectedAudioIndex {
            metadata.append(.audioTrackIndex(selectedAudioIndex))
        }
        diagnostics.record(
            category: .audio,
            level: .notice,
            event: .silentMarker,
            correlationID: playbackCorrelationID,
            metadata: metadata
        )
        silentMarkerFollowUpTask?.cancel()
        silentMarkerFollowUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.recordAudioSnapshot(level: .notice)
        }
    }

    private func resolveAndPlay(file: CloudFile, at position: Double, requestGeneration: Int) async throws {
        let requestedFile = file
        lastRequestedPlaybackFileID = requestedFile.fileId
        message = nil
        let resource: PlaybackResource
        do {
            if let sourceID = requestedFile.sourceID,
               !sourceID.isEmpty,
               sourceID != "quark-default",
               let adapter = sourceRepository.adapter(for: sourceID, client: client) {
                resource = try await adapter.playbackResource(fileID: requestedFile.fileId)
            } else {
                resource = try await client.playbackResource(
                    fileID: requestedFile.fileId,
                    correlationID: playbackCorrelationID
                )
            }
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

        let allowLocalUITestFile = ProcessInfo.processInfo.arguments.contains("--uitest-player")
        guard Self.isPlaybackURLAllowed(resource.url, allowLocalUITestFile: allowLocalUITestFile) else {
            throw QuarkError.unsupportedPlayback("仅允许 HTTPS 播放地址。")
        }

        var customHeaders = resource.requiredHTTPHeaders
        if resource.url.scheme?.lowercased() == "https", customHeaders["User-Agent"] == nil {
            customHeaders["User-Agent"] = customHeaders.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 quark-cloud-drive/2.5.20"
        }
        if resource.url.scheme?.lowercased() == "https", customHeaders["Referer"] == nil {
            customHeaders["Referer"] = "https://pan.quark.cn/"
        }
        if resource.url.scheme?.lowercased() == "https", customHeaders["Origin"] == nil {
            customHeaders["Origin"] = "https://pan.quark.cn"
        }
        let applicableCookies = PlaybackProbe.applicableCookies(resource.cookies, url: resource.url)
        if !applicableCookies.isEmpty && customHeaders["Cookie"] == nil {
            let cookieHeader = applicableCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            customHeaders["Cookie"] = cookieHeader
        }

        let resolvedResource = PlaybackResource(
            fileID: resource.fileID,
            url: resource.url,
            cookies: applicableCookies,
            requiredHTTPHeaders: customHeaders,
            expiresAt: resource.expiresAt
        )

        activeResource = resolvedResource
        audioTracks = []
        subtitleTracks = []
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        restoredPosition = position
        pendingRestoration = position > 0 ? (requestGeneration, position) : nil
        currentEpisodeMarkers = .empty
        markerResolutionTriggeredGeneration = nil
        markerResolutionTask?.cancel()
        markerResolutionTask = nil

        engine.load(resolvedResource, generation: requestGeneration)
    }

    private func triggerMarkerResolution(fileID: String, generation requestGeneration: Int, duration: Double) {
        guard duration.isFinite && duration > 0 else { return }
        markerResolutionTask?.cancel()
        markerResolutionTask = Task { @MainActor [weak self, accountID] in
            guard let self, self.generation == requestGeneration, self.currentFile.fileId == fileID else { return }
            let catalogURL = StoragePaths.mediaCatalogDatabaseURL()
            let catalog = catalogURL.flatMap { try? MediaCatalogRepository(url: $0) }
            guard let confirmed = try? catalog?.confirmedItem(accountID: accountID, fileID: fileID),
                  confirmed.mediaType == .series,
                  let tmdbID = confirmed.tmdbId, tmdbID > 0,
                  let season = confirmed.seasonNumber, season >= 0,
                  let episode = confirmed.episodeNumber, episode > 0 else {
                return
            }
            let token = TMDBCredentialStore().effectiveToken()

            let markers = await IntroSkipMarkerService.shared.resolveMarkers(
                tmdbID: tmdbID,
                season: season,
                episode: episode,
                duration: duration,
                fileID: fileID,
                repository: catalog,
                tmdbToken: token
            )

            // 应用结果再次验证 duration 和 generation/fileID
            guard !Task.isCancelled,
                  self.generation == requestGeneration,
                  self.currentFile.fileId == fileID else { return }

            let currentDuration = self.playbackDuration
            guard currentDuration.isFinite && currentDuration > 0 else { return }

            let validated = IntroSkipMarkerService.validateAndClamp(markers: markers, duration: currentDuration)
            self.currentEpisodeMarkers = validated
        }
    }

    private func handleEngineEvent(_ event: PlaybackEngineEvent) {
        guard event.generation == generation else { return }

        switch event {
        case .stateChanged(let snapshot):
            applySnapshot(snapshot)

        case .ready(let snapshot):
            applySnapshot(snapshot)
            if let pendingRestoration,
               pendingRestoration.generation == generation,
               pendingRestoration.position > 0 {
                self.pendingRestoration = nil
                engine.seek(to: pendingRestoration.position)
            }
            recordStartedDiagnostics()

        case .tracksChanged(_, let audio, let subtitles, let selectedAudioID, let selectedSubtitleID):
            self.audioTracks = audio
            self.subtitleTracks = subtitles
            selectedAudioIndex = selectedAudioID.flatMap { id in
                audio.firstIndex { $0.id == id }
            }
            let selectableSubtitles = subtitles.filter { !$0.isDisabled }
            selectedSubtitleIndex = selectedSubtitleID.flatMap { id in
                selectableSubtitles.firstIndex { $0.id == id }
            }

        case .ended:
            isPlaying = false
            isBuffering = false
            stopSnapshotPolling()
            saveProgress()
            diagnostics.record(
                category: .playback,
                level: .info,
                event: .playbackState,
                correlationID: playbackCorrelationID,
                metadata: [.playerState(.ended), .playbackTimeSeconds(playbackTime)]
            )
            if automaticallyPlayNext {
                playNext()
            } else if canPlayNext {
                message = "本集已播放完成，可选择播放下一集。"
            }

        case .failed(let error, _):
            isPlaying = false
            isBuffering = false
            stopSnapshotPolling()
            handlePlaybackFailure(error)

        case .diagnostic:
            break
        }
    }

    private func applySnapshot(_ snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot

        let now = Date()
        bufferingPolicyState = bufferingPolicy.updating(
            currentTime: snapshot.currentTime,
            state: snapshot.state,
            generation: snapshot.generation,
            now: now,
            previousState: bufferingPolicyState
        )

        switch snapshot.state {
        case .playing:
            isPlaying = true
            isBuffering = false
            if let pending = pendingFile {
                committedActiveFile = pending
                pendingFile = nil
            }
            activePlayingFileID = committedActiveFile.fileId
            isCurrentPlaybackStarted = true
            isPlaybackTransitionActive = false
            startSnapshotPolling()
            if snapshot.duration > 0 && markerResolutionTriggeredGeneration != generation {
                markerResolutionTriggeredGeneration = generation
                triggerMarkerResolution(fileID: committedActiveFile.fileId, generation: generation, duration: snapshot.duration)
            }
        case .buffering:
            isPlaying = true
            isBuffering = bufferingPolicy.shouldDisplayBuffering(
                engineState: .buffering,
                policyState: bufferingPolicyState,
                now: now
            )
        case .loading:
            isBuffering = false
        case .ready:
            isPlaying = false
            isBuffering = false
        case .paused:
            isPlaying = false
            isBuffering = false
            bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
            stopSnapshotPolling()
        case .ended, .idle:
            isPlaying = false
            isBuffering = false
            bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
            stopSnapshotPolling()
        case .failed:
            isPlaying = false
            isBuffering = false
            bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
            stopSnapshotPolling()
        }

        if snapshot.networkRate > 0 {
            let speedKB = snapshot.networkRate / 1024.0
            if speedKB > 1024 {
                networkSpeedText = String(format: "%.1f MB/s", speedKB / 1024.0)
            } else {
                networkSpeedText = String(format: "%.0f KB/s", speedKB)
            }
        } else {
            networkSpeedText = ""
        }
    }

    private func startSnapshotPolling() {
        guard snapshotPollTask == nil else { return }
        let currentGen = generation
        snapshotPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, self.generation == currentGen else { break }
                if self.hasActivePlayer {
                    self.applySnapshot(self.engine.snapshot)
                }
            }
        }
    }

    private func stopSnapshotPolling() {
        snapshotPollTask?.cancel()
        snapshotPollTask = nil
    }

    private func recordStartedDiagnostics() {
        guard startedPlaybackGeneration != generation else { return }
        startedPlaybackGeneration = generation
        var metadata: [DiagnosticMetadata] = [
            .endpoint(.filePlay),
            .playerEngine(.vlcPlayer),
            .switchGeneration(generation)
        ]
        if let ordinal = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) {
            metadata.append(.episodeOrdinal(ordinal))
        }
        diagnostics.record(
            category: .playback,
            level: .info,
            event: .started,
            correlationID: playbackCorrelationID,
            metadata: metadata
        )
    }

    private func handlePlaybackFailure(_ error: Error) {
        saveProgress()
        guard Self.shouldScheduleRetry(
            currentGeneration: generation,
            scheduledGeneration: retryScheduledGeneration,
            retryTaskActive: retryTask != nil && !(retryTask?.isCancelled ?? true)
        ) else { return }

        guard let delay = retryPolicy.delay(for: error, retriesUsed: retriesUsed) else {
            activeResource = nil
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
                try await self.resolveAndPlay(
                    file: self.pendingFile ?? self.currentFile,
                    at: self.playbackTime,
                    requestGeneration: retryGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == retryGeneration else { return }
                self.activeResource = nil
                self.pendingFile = nil
                self.isPlaybackTransitionActive = false
                self.isCurrentPlaybackStarted = false
                self.report(error)
            }
        }
    }

    private func startRetryLoop() async {
        isResolvingResource = true
        defer { isResolvingResource = false }
        generation += 1
        let requestGeneration = generation
        bufferingPolicyState = PlaybackBufferingPolicy.State.reset(for: generation)
        do {
            try await resolveAndPlay(
                file: pendingFile ?? currentFile,
                at: playbackTime,
                requestGeneration: requestGeneration
            )
            message = nil
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

    private func report(_ error: Error) {
        message = error.localizedDescription
        diagnostics.record(
            category: .playback,
            level: .error,
            event: .playbackError,
            correlationID: playbackCorrelationID,
            metadata: [.playerState(.failed), .status(.failed), .errorCode((error as NSError).code), .playerEngine(.vlcPlayer)]
        )
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

    private func recordAudioSnapshot(level: DiagnosticLevel) {
        let session = AVAudioSession.sharedInstance()
        diagnostics.record(
            category: .audio,
            level: level,
            event: .audioSnapshot,
            correlationID: playbackCorrelationID,
            metadata: [
                .trackCount(audioTracks.count),
                .route(currentAudioRoute),
                .playbackTimeSeconds(playbackTime),
                .audioOutputChannels(session.outputNumberOfChannels),
                .audioVolume(Double(session.outputVolume)),
                .playerEngine(.vlcPlayer)
            ]
        )
    }

    private func installAudioRouteObserver() {
        guard audioRouteObserver == nil else { return }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.diagnostics.record(
                    category: .audio,
                    level: .notice,
                    event: .audioRouteChanged,
                    correlationID: self.playbackCorrelationID,
                    metadata: [.route(self.currentAudioRoute)]
                )
                self.recordAudioSnapshot(level: .notice)
            }
        }
    }

    private func removeAudioRouteObserver() {
        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
            audioRouteObserver = nil
        }
    }
}

// MARK: - Episode Resume Resolver
/// Pure episode resume resolver using complete WatchHistory (lastWatchedAt and completed).
enum EpisodeResumeResolver {
    static func resolve(
        episodes: [(MediaItem, CloudFile, ParsedMediaName)],
        historyByFileID: [String: WatchHistory],
        isSeries: Bool
    ) -> (MediaItem, CloudFile, ParsedMediaName)? {
        guard !episodes.isEmpty else { return nil }

        // 1. Check if any episode has watch history
        let episodesWithHistory = episodes.compactMap { ep -> (ep: (MediaItem, CloudFile, ParsedMediaName), history: WatchHistory)? in
            guard let hist = historyByFileID[ep.1.fileId] else { return nil }
            return (ep, hist)
        }

        if !episodesWithHistory.isEmpty {
            // Find the most recently watched episode by lastWatchedAt
            let latestWatched = episodesWithHistory.max { a, b in
                a.history.lastWatchedAt < b.history.lastWatchedAt
            }!

            let isCompleted = latestWatched.history.completed ||
                (latestWatched.history.durationSeconds > 0 &&
                 latestWatched.history.positionSeconds >= latestWatched.history.durationSeconds * 0.95)

            if !isCompleted {
                // Return the in-progress episode
                return latestWatched.ep
            } else {
                // When completed, advance to subsequent episode
                if let currentIndex = episodes.firstIndex(where: { $0.1.fileId == latestWatched.ep.1.fileId }),
                   currentIndex + 1 < episodes.count {
                    return episodes[currentIndex + 1]
                }
                // If it was the last episode, return the completed last episode as conservative fallback for series (avoid jumping back to S1E1)
                if isSeries {
                    return latestWatched.ep
                }
                return latestWatched.ep
            }
        }

        // 2. No history: existing product semantics
        if isSeries {
            return episodes.first(where: { $0.2.episodeNumber != nil }) ?? episodes.first
        }
        return episodes.first
    }
}
