#if canImport(TVVLCKit)
@preconcurrency import TVVLCKit
import AVFoundation
import Combine
import Foundation
import UIKit

enum VLCPlaybackObservableState: Equatable {
    case idle
    case loading
    case buffering
    case playing
    case paused
    case ended
    case failed
}

enum VLCPlaybackStateMapper {
    /// Values mirror VLCMediaPlayerState in TVVLCKit (VLCMediaPlayer.h:55-65).
    static func map(rawValue: Int, currentState: VLCPlaybackObservableState? = nil) -> VLCPlaybackObservableState {
        switch rawValue {
        case 0: return .idle
        case 1: return .loading
        case 2: return .buffering
        case 3: return .ended
        case 4: return .failed
        case 5: return .playing
        case 6: return .paused
        case 7:
            // VLCMediaPlayerStateESAdded: Elementary Stream added (VLCMediaPlayer.h:64).
            // Informational track discovery event; unconditionally preserves currentState when known,
            // or defaults to neutral .idle when unknown.
            if let currentState {
                return currentState
            }
            return .idle
        default: return .failed
        }
    }

    static func engineState(for observableState: VLCPlaybackObservableState) -> PlaybackEngineState {
        switch observableState {
        case .idle: return .idle
        case .loading: return .loading
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .failed: return .failed
        }
    }
}

enum VLCPlaybackError: LocalizedError, Equatable {
    case cookieInjectionFailed
    case staleMediaEvent

    var errorDescription: String? {
        switch self {
        case .cookieInjectionFailed:
            return "VLC 无法注入播放 Cookie"
        case .staleMediaEvent:
            return "VLC 收到已失效媒体的事件"
        }
    }
}

/// Production TVVLCKit playback engine implementation of PlaybackEngine protocol.
/// PlaybackCoordinator owns queueing, history, retries, and resource resolution.
@MainActor
final class VLCPlaybackController: NSObject, ObservableObject, PlaybackEngine {
    // MARK: - PlaybackEngine Protocol Properties

    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    private(set) var snapshot = PlaybackSnapshot.idle()
    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []

    // MARK: - Observable Properties (Preserved for compatibility)

    @Published private(set) var state: VLCPlaybackObservableState = .idle
    @Published private(set) var currentTimeSeconds: Double = 0.0
    @Published private(set) var durationSeconds: Double = 0.0
    @Published private(set) var isSeekable = false
    @Published private(set) var hasVideoOutput = false
    @Published private(set) var isMuted = false
    @Published private(set) var audioVolume: Double = 1.0
    @Published private(set) var route: DiagnosticAudioRoute = .unknown
    @Published private(set) var errorMessage: String?

    // MARK: - Internal Engine State

    private let diagnostics: Diagnostics?
    private let correlationID: DiagnosticCorrelationID?
    private var player: VLCMediaPlayer?
    private var media: VLCMedia?
    private var originProxy: VLCOriginHTTPProxy?
    private weak var surface: UIView?
    private var generation = 0
    private var mediaIdentifier = ""
    private var pollTask: Task<Void, Never>?
    private var readyGeneration: Int?
    private var lastDiagnosticState: PlaybackEngineState?
    private var lastDiagnosticRoute: DiagnosticAudioRoute?
    private var lastPeriodicDiagnosticDate: Date?
    private let periodicDiagnosticInterval: TimeInterval = 15

    // MARK: - Initialization

    init(diagnostics: Diagnostics? = nil) {
        self.diagnostics = diagnostics
        self.correlationID = diagnostics?.makeCorrelationID()
        super.init()
    }

    /// Preserved compatibility initializer. Owns no QuarkClient or file resolution.
    @available(*, deprecated, message: "Use init(diagnostics:) and load(_:generation:) instead")
    convenience init(client: QuarkClient, file: CloudFile, diagnostics: Diagnostics) {
        self.init(diagnostics: diagnostics)
    }

    // MARK: - PlaybackEngine Protocol Methods

    func attachSurface(_ surface: UIView?) {
        self.surface = surface
        player?.drawable = surface
    }

    func load(_ resource: PlaybackResource, generation: Int) {
        // Detach old delegate/drawable/media and stop old player
        tearDownPlayer(resetSurface: false)

        self.generation = generation
        self.mediaIdentifier = resource.url.absoluteString
        self.errorMessage = nil
        self.readyGeneration = nil

        updateSnapshot(state: .loading, time: 0, duration: 0, buffered: 0, networkRate: 0, hasVideoOutput: false)
        emit(.stateChanged(snapshot))

        do {
            let plan = VLCPlaybackPlanning.plan(resource: resource)
            if plan.requiresOriginProxy {
                let proxy = VLCOriginHTTPProxy(resource: resource)
                originProxy = proxy
                Task { @MainActor [weak self] in
                    do {
                        let localURL = try await proxy.start()
                        guard let self, self.generation == generation else {
                            proxy.stop()
                            return
                        }
                        try self.configurePlayer(plan: plan, url: localURL)
                    } catch {
                        proxy.stop()
                        if self?.originProxy === proxy { self?.originProxy = nil }
                        guard let self, self.generation == generation else { return }
                        self.fail(error)
                    }
                }
            } else {
                try configurePlayer(plan: plan, url: resource.url)
            }
        } catch {
            fail(error)
        }
    }

    private func configurePlayer(plan: VLCPlaybackPlan, url: URL) throws {
        let media = VLCMedia(url: url)
        for option in plan.mediaOptions {
            media.addOption(option)
        }
        for cookie in plan.cookieInjections {
            guard media.storeCookie(cookie.setCookieValue, forHost: cookie.host, path: cookie.path) == 0 else {
                throw VLCPlaybackError.cookieInjectionFailed
            }
        }

        let player = VLCMediaPlayer(options: [])
        player.delegate = self
        player.media = media
        player.drawable = surface

        self.media = media
        self.player = player
        startPolling()
        player.play()
    }

    func play() {
        player?.play()
        pollSnapshot()
    }

    func pause() {
        player?.pause()
        pollSnapshot()
    }

    func stop() {
        tearDownPlayer(resetSurface: true)
        generation &+= 1
        mediaIdentifier = ""
        audioTracks = []
        subtitleTracks = []
        updateSnapshot(state: .idle, time: 0, duration: 0, buffered: 0, networkRate: 0, hasVideoOutput: false)
        emit(.stateChanged(snapshot))
    }

    @discardableResult
    func seek(to seconds: TimeInterval) -> Bool {
        guard let player, player.isSeekable else { return false }
        let duration = snapshot.duration
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let targetMs = min(Int64((target * 1000).rounded()), Int64(Int32.max))
        player.time = VLCTime(int: Int32(targetMs))
        diagnostics?.record(
            category: .playback,
            level: .debug,
            event: .playbackSeek,
            correlationID: correlationID,
            metadata: [.playerEngine(.vlcPlayer), .playbackTimeSeconds(target)]
        )
        pollSnapshot()
        return true
    }

    func selectAudioTrack(id: Int?) {
        let trackID = id.map(Int32.init) ?? -1
        player?.currentAudioTrackIndex = trackID
        pollSnapshot()
    }

    func selectSubtitleTrack(id: Int?) {
        let trackID = id.map(Int32.init) ?? -1
        player?.currentVideoSubTitleIndex = trackID
        pollSnapshot()
    }

    // MARK: - Preserved Compatibility Methods

    @available(*, deprecated, message: "Use attachSurface(_:)")
    func attachDrawable(_ view: UIView) {
        attachSurface(view)
    }

    @available(*, deprecated, message: "Use load(_:generation:)")
    func start() {
        fail(VLCPlaybackError.staleMediaEvent)
    }

    func togglePlayPause() {
        if player?.isPlaying == true {
            pause()
        } else {
            play()
        }
    }

    @discardableResult
    func seek(deltaSeconds: Double) -> Bool {
        seek(to: snapshot.currentTime + deltaSeconds)
    }

    func markSilent() {
        pollSnapshot()
        diagnostics?.record(
            category: .audio,
            level: .notice,
            event: .silentMarker,
            correlationID: correlationID,
            metadata: diagnosticMetadata() + [.playerEngine(.vlcPlayer)]
        )
    }

    // MARK: - Delegate Event Handlers

    func handleMediaPlayerStateChanged(notifyingObjectID: ObjectIdentifier?) {
        guard isCurrent(notifyingObjectID: notifyingObjectID) else { return }
        guard let player else { return }

        let raw = player.state.rawValue
        let mapped = VLCPlaybackStateMapper.map(rawValue: raw, currentState: self.state)
        let engineState = VLCPlaybackStateMapper.engineState(for: mapped)
        updateFromPlayer(state: engineState)

        switch mapped {
        case .ended:
            emit(.ended(snapshot))
        case .failed:
            let error = NSError(
                domain: "org.quarktheater.vlc",
                code: raw,
                userInfo: [NSLocalizedDescriptionKey: "VLC media player entered error state"]
            )
            fail(error)
        case .playing, .paused:
            discoverTracks()
            if readyGeneration != generation {
                readyGeneration = generation
                emit(.ready(snapshot))
            } else {
                emit(.stateChanged(snapshot))
            }
        case .loading, .buffering:
            discoverTracks()
            emit(.stateChanged(snapshot))
        case .idle:
            emit(.stateChanged(snapshot))
        }
    }

    func handleMediaPlayerTimeChanged(notifyingObjectID: ObjectIdentifier?) {
        guard isCurrent(notifyingObjectID: notifyingObjectID) else { return }
        pollSnapshot()
    }

    // MARK: - Snapshot & Polling

    func pollSnapshot() {
        guard let player else { return }
        let priorState = snapshot.state
        let mapped = VLCPlaybackStateMapper.map(rawValue: player.state.rawValue, currentState: self.state)
        updateFromPlayer(state: VLCPlaybackStateMapper.engineState(for: mapped))

        if snapshot.state != priorState {
            emit(.stateChanged(snapshot))
        }

        let now = Date()
        let periodic = lastPeriodicDiagnosticDate.map {
            now.timeIntervalSince($0) >= periodicDiagnosticInterval
        } ?? true

        if snapshot.state != lastDiagnosticState || route != lastDiagnosticRoute || periodic {
            lastDiagnosticState = snapshot.state
            lastDiagnosticRoute = route
            lastPeriodicDiagnosticDate = now
            diagnostics?.record(
                category: .playback,
                level: .debug,
                event: .playbackState,
                correlationID: correlationID,
                metadata: diagnosticMetadata() + [.playerEngine(.vlcPlayer)]
            )
            emit(.diagnostic(diagnosticSnapshot()))
        }
    }

    private func updateFromPlayer(state: PlaybackEngineState) {
        guard let player else { return }
        let time = max(0, (player.time.value?.doubleValue ?? 0) / 1000)
        var duration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1000)
        if duration <= 0, let proxyDuration = originProxy?.activeVODDuration(), proxyDuration > 0 {
            duration = proxyDuration
        }
        var rate: Double = 0
        if let proxyRate = originProxy?.currentThroughputBytesPerSecond(), proxyRate > 0 {
            rate = proxyRate
        }

        isSeekable = player.isSeekable
        hasVideoOutput = player.hasVideoOut
        currentTimeSeconds = time
        durationSeconds = duration
        route = Self.audioRoute()

        if let audio = player.audio {
            isMuted = audio.isMuted
            audioVolume = min(max(Double(audio.volume) / 100, 0), 1)
        }

        originProxy?.updatePlayhead(time)
        let ranges = originProxy?.currentBufferedRanges() ?? []
        updateSnapshot(
            state: state,
            time: time,
            duration: duration,
            buffered: 0,
            networkRate: rate,
            hasVideoOutput: player.hasVideoOut,
            bufferedRanges: ranges
        )
    }

    private func updateSnapshot(
        state: PlaybackEngineState,
        time: TimeInterval,
        duration: TimeInterval,
        buffered: TimeInterval,
        networkRate: Double,
        hasVideoOutput: Bool,
        bufferedRanges: [PlaybackTimeRange] = []
    ) {
        self.state = Self.observableState(state)
        self.snapshot = PlaybackSnapshot(
            generation: generation,
            state: state,
            currentTime: time,
            duration: duration,
            bufferedTime: buffered,
            networkRate: networkRate,
            hasVideoOutput: hasVideoOutput,
            bufferedRanges: bufferedRanges
        )
    }

    // MARK: - Track Discovery

    private func discoverTracks() {
        guard let player else { return }
        let langLookup = Self.buildLanguageLookup(media: player.media)

        let audioNames = player.audioTrackNames.map { String(describing: $0) }
        let audioIDs = player.audioTrackIndexes.compactMap(Self.intValue)
        self.audioTracks = Self.processDiscoveredAudioTracks(ids: audioIDs, names: audioNames, languages: langLookup)

        let subNames = player.videoSubTitlesNames.map { String(describing: $0) }
        let subIDs = player.videoSubTitlesIndexes.compactMap(Self.intValue)
        self.subtitleTracks = Self.processDiscoveredSubtitleTracks(ids: subIDs, names: subNames, languages: langLookup)

        emit(.tracksChanged(
            generation: generation,
            audio: audioTracks,
            subtitles: subtitleTracks,
            selectedAudioID: Self.activeTrackID(player.currentAudioTrackIndex),
            selectedSubtitleID: Self.activeTrackID(player.currentVideoSubTitleIndex)
        ))
    }

    /// VLC uses -1 for a disabled or unavailable track. Keep that sentinel out
    /// of the engine contract so the coordinator can represent it as nil.
    static func activeTrackID(_ rawID: Int32) -> Int? {
        rawID >= 0 ? Int(rawID) : nil
    }

    static func processDiscoveredAudioTracks(
        ids: [Int],
        names: [String],
        languages: [Int: String] = [:]
    ) -> [PlaybackTrack] {
        zip(ids, names).compactMap { (id: Int, name: String) -> PlaybackTrack? in
            guard id >= 0, !isDisabledName(name) else { return nil }
            return PlaybackTrack(
                id: id,
                kind: .audio,
                name: name,
                languageCode: languages[id],
                isDisabled: false
            )
        }
    }

    static func processDiscoveredSubtitleTracks(
        ids: [Int],
        names: [String],
        languages: [Int: String] = [:]
    ) -> [PlaybackTrack] {
        var tracks = [
            PlaybackTrack(id: -1, kind: .subtitle, name: "关闭字幕", languageCode: nil, isDisabled: true)
        ]
        let realTracks: [PlaybackTrack] = zip(ids, names).compactMap { (id: Int, name: String) -> PlaybackTrack? in
            guard id >= 0, !isDisabledName(name) else { return nil }
            return PlaybackTrack(
                id: id,
                kind: .subtitle,
                name: name,
                languageCode: languages[id],
                isDisabled: false
            )
        }
        tracks.append(contentsOf: realTracks)
        return tracks
    }

    private static func buildLanguageLookup(media: VLCMedia?) -> [Int: String] {
        guard let tracks = media?.tracksInformation else { return [:] }
        var result: [Int: String] = [:]
        for item in tracks {
            guard let dict = item as? [String: Any],
                  let idNum = dict[VLCMediaTracksInformationId] as? NSNumber,
                  let lang = dict[VLCMediaTracksInformationLanguage] as? String,
                  !lang.isEmpty else { continue }
            result[idNum.intValue] = lang
        }
        return result
    }

    // MARK: - Teardown & Lifecycle

    private func tearDownPlayer(resetSurface: Bool) {
        originProxy?.stop()
        originProxy = nil
        pollTask?.cancel()
        pollTask = nil
        player?.delegate = nil
        player?.stop()
        player?.drawable = nil
        player?.media = nil
        player = nil
        media = nil
        if resetSurface {
            surface = nil
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollSnapshot()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        updateSnapshot(
            state: .failed,
            time: snapshot.currentTime,
            duration: snapshot.duration,
            buffered: snapshot.bufferedTime,
            networkRate: snapshot.networkRate,
            hasVideoOutput: hasVideoOutput
        )
        diagnostics?.record(
            category: .playback,
            level: .error,
            event: .playbackError,
            correlationID: correlationID,
            metadata: diagnosticMetadata() + [.playerEngine(.vlcPlayer), .errorCode((error as NSError).code)]
        )
        emit(.failed(error: error, snapshot: snapshot))
    }

    private func isCurrent(notifyingObjectID: ObjectIdentifier?) -> Bool {
        guard let player, let notifyingObjectID else { return false }
        guard ObjectIdentifier(player) == notifyingObjectID else { return false }
        return true
    }

    private func emit(_ event: PlaybackEngineEvent) {
        eventHandler?(event)
    }

    // MARK: - Diagnostics Helpers

    private func diagnosticSnapshot() -> PlaybackDiagnosticSnapshot {
        let s = media?.statistics
        return PlaybackDiagnosticSnapshot(
            generation: generation,
            mediaIdentifier: mediaIdentifier,
            state: snapshot.state,
            hasVideoOutput: hasVideoOutput,
            decodedAudioBuffers: Int(s?.decodedAudio ?? 0),
            lostAudioBuffers: Int(s?.lostAudioBuffers ?? 0),
            decodedVideoFrames: Int(s?.decodedVideo ?? 0),
            lostVideoFrames: Int(s?.lostPictures ?? 0)
        )
    }

    private func diagnosticMetadata() -> [DiagnosticMetadata] {
        var m: [DiagnosticMetadata] = [
            .playerState(Self.diagnosticState(state)),
            .playbackTimeSeconds(currentTimeSeconds),
            .route(route),
            .audioMuted(isMuted),
            .audioPlaybackVolume(audioVolume),
            .videoTrackPresent(hasVideoOutput)
        ]
        if let s = media?.statistics {
            m += [
                .vlcDecodedAudioBlocks(Int(s.decodedAudio)),
                .vlcPlayedAudioBuffers(Int(s.playedAudioBuffers)),
                .vlcLostAudioBuffers(Int(s.lostAudioBuffers)),
                .vlcDecodedVideoBlocks(Int(s.decodedVideo)),
                .vlcDisplayedPictures(Int(s.displayedPictures)),
                .vlcLostPictures(Int(s.lostPictures))
            ]
        }
        return m
    }

    private static func intValue(_ value: Any) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return Int(String(describing: value))
    }

    static func isDisabledName(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.caseInsensitiveCompare("disabled") == .orderedSame || v.caseInsensitiveCompare("disable") == .orderedSame || v == "关闭字幕" || v == "关闭"
    }

    private static func observableState(_ s: PlaybackEngineState) -> VLCPlaybackObservableState {
        switch s {
        case .idle: return .idle
        case .loading, .ready: return .loading
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .failed: return .failed
        }
    }

    private static func diagnosticState(_ s: VLCPlaybackObservableState) -> DiagnosticPlayerState {
        switch s {
        case .idle: return .idle
        case .loading: return .loading
        case .buffering: return .waiting
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .failed: return .failed
        }
    }

    private static func audioRoute() -> DiagnosticAudioRoute {
        switch AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType {
        case .airPlay: return .airPlay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        case .builtInSpeaker, .builtInReceiver: return .builtIn
        case .HDMI, .displayPort: return .hdmi
        default: return .unknown
        }
    }
}

extension VLCPlaybackController: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        let objectID = (aNotification.object as AnyObject?).map(ObjectIdentifier.init)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleMediaPlayerStateChanged(notifyingObjectID: objectID)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.handleMediaPlayerStateChanged(notifyingObjectID: objectID)
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let objectID = (aNotification.object as AnyObject?).map(ObjectIdentifier.init)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleMediaPlayerTimeChanged(notifyingObjectID: objectID)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.handleMediaPlayerTimeChanged(notifyingObjectID: objectID)
            }
        }
    }
}
#endif
