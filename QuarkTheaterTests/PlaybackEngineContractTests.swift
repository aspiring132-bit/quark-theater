import Foundation
import UIKit
import XCTest
@testable import QuarkTheater

@MainActor
final class PlaybackEngineContractTests: XCTestCase {
    func testSnapshotAndTrackKeepGenerationAndRealIDs() {
        let snapshot = PlaybackSnapshot(generation: 7, state: .playing,
                                        currentTime: 12, duration: 120,
                                        bufferedTime: 30, networkRate: 1_000_000,
                                        hasVideoOutput: true)
        let audio = PlaybackTrack(id: 42, kind: .audio, name: "中文", languageCode: "zh", isDisabled: false)
        let subtitles = PlaybackTrack(id: -1, kind: .subtitle, name: "关闭字幕", languageCode: nil, isDisabled: true)

        XCTAssertEqual(snapshot.generation, 7)
        XCTAssertEqual(audio.id, 42)
        XCTAssertEqual(subtitles.id, -1)
        XCTAssertTrue(subtitles.isDisabled)
    }

    func testEngineContractForwardsCommandsAndTagsEvents() {
        let engine = ContractFakeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.eventHandler = { events.append($0) }
        let resource = PlaybackResource(fileID: "episode-1", url: URL(string: "https://example.com/1.mp4")!,
                                        cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
        engine.load(resource, generation: 3)
        engine.play()
        engine.seek(to: 15)
        engine.pause()

        XCTAssertEqual(engine.loadedGeneration, 3)
        XCTAssertEqual(engine.loadedResource?.fileID, "episode-1")
        XCTAssertEqual(engine.commands, [.play, .seek(15), .pause])
        XCTAssertEqual(events.map(\.generation), [3, 3])
    }

    func testTrackSelectionForwardsStableRealIDsAndTracksEventGeneration() {
        let engine = ContractFakeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.load(PlaybackResource(fileID: "episode-2", url: URL(string: "https://example.com/2.mkv")!,
                                     cookies: [], requiredHTTPHeaders: [:], expiresAt: nil), generation: 9)
        engine.selectAudioTrack(id: 42)
        engine.selectSubtitleTrack(id: -1)

        XCTAssertEqual(engine.selectedAudioID, 42)
        XCTAssertEqual(engine.selectedSubtitleID, -1)
        XCTAssertEqual(events.map(\.generation), [9, 9])
    }

    func testBufferingPolicySuppressesIndicatorWhenRecentProgressWithinGraceWindow() {
        let now = Date(timeIntervalSince1970: 100)
        let policy = PlaybackBufferingPolicy(graceWindow: 1.0, minimumProgress: 0.05)

        // Advancing playback time updates lastProgressAt to now
        let state = policy.updating(
            currentTime: 10.5,
            state: .buffering,
            generation: 1,
            now: now,
            previousState: PlaybackBufferingPolicy.State(
                lastPlaybackTime: 10.0,
                lastProgressAt: now,
                generation: 1
            )
        )

        // Within grace window (e.g. 0.5s later), buffering indicator should be hidden (suppressed)
        let isBufferingDisplayed = policy.shouldDisplayBuffering(
            engineState: .buffering,
            policyState: state,
            now: now.addingTimeInterval(0.5)
        )
        XCTAssertFalse(isBufferingDisplayed)
    }

    func testBufferingPolicyShowsIndicatorWhenProgressIsStaleOrNone() {
        let baseline = Date(timeIntervalSince1970: 100)
        let policy = PlaybackBufferingPolicy(graceWindow: 1.0, minimumProgress: 0.05)

        // 1. Stale progress: last progress was 100, now is 101.5 (> grace window of 1.0s) with no new progress
        let staleState = policy.updating(
            currentTime: 10.0,
            state: .buffering,
            generation: 1,
            now: baseline.addingTimeInterval(1.5),
            previousState: PlaybackBufferingPolicy.State(
                lastPlaybackTime: 10.0,
                lastProgressAt: baseline,
                generation: 1
            )
        )
        let showStale = policy.shouldDisplayBuffering(
            engineState: .buffering,
            policyState: staleState,
            now: baseline.addingTimeInterval(1.5)
        )
        XCTAssertTrue(showStale)

        // 2. No progress at all (e.g. starting buffering from zero progress)
        let noProgressState = policy.updating(
            currentTime: 0.0,
            state: .buffering,
            generation: 1,
            now: baseline,
            previousState: nil
        )
        let showNoProgress = policy.shouldDisplayBuffering(
            engineState: .buffering,
            policyState: noProgressState,
            now: baseline
        )
        XCTAssertTrue(showNoProgress)
    }

    func testBufferingPolicyHidesIndicatorWhenEngineIsNotBuffering() {
        let now = Date(timeIntervalSince1970: 100)
        let policy = PlaybackBufferingPolicy(graceWindow: 1.0, minimumProgress: 0.05)

        let playingState = policy.updating(
            currentTime: 10.0,
            state: .playing,
            generation: 1,
            now: now,
            previousState: nil
        )
        XCTAssertFalse(policy.shouldDisplayBuffering(
            engineState: .playing,
            policyState: playingState,
            now: now
        ))

        let pausedState = policy.updating(
            currentTime: 10.0,
            state: .paused,
            generation: 1,
            now: now,
            previousState: nil
        )
        XCTAssertFalse(policy.shouldDisplayBuffering(
            engineState: .paused,
            policyState: pausedState,
            now: now
        ))

        let readyState = policy.updating(
            currentTime: 10.0,
            state: .ready,
            generation: 1,
            now: now,
            previousState: nil
        )
        XCTAssertFalse(policy.shouldDisplayBuffering(
            engineState: .ready,
            policyState: readyState,
            now: now
        ))
    }

    func testBufferingPolicyResetsBaselineOnGenerationChangeOrReset() {
        let baseline = Date(timeIntervalSince1970: 100)
        let policy = PlaybackBufferingPolicy(graceWindow: 1.0, minimumProgress: 0.05)

        let previousState = PlaybackBufferingPolicy.State(
            lastPlaybackTime: 10.0,
            lastProgressAt: baseline,
            generation: 1
        )

        // Generation change resets progress tracking
        let newGenState = policy.updating(
            currentTime: 10.0,
            state: .buffering,
            generation: 2,
            now: baseline.addingTimeInterval(0.2),
            previousState: previousState
        )
        XCTAssertNil(newGenState.lastProgressAt)
        XCTAssertEqual(newGenState.generation, 2)
        XCTAssertTrue(policy.shouldDisplayBuffering(
            engineState: .buffering,
            policyState: newGenState,
            now: baseline.addingTimeInterval(0.2)
        ))

        // Explicit reset (e.g. seek / pause)
        let resetState = PlaybackBufferingPolicy.State.reset(for: 1)
        XCTAssertNil(resetState.lastProgressAt)
        XCTAssertNil(resetState.lastPlaybackTime)
        XCTAssertTrue(policy.shouldDisplayBuffering(
            engineState: .buffering,
            policyState: resetState,
            now: baseline
        ))
    }

    func testDiagnosticIdentifierRedactsQueryAndFragment() {
        let diagnostic = PlaybackDiagnosticSnapshot(
            generation: 4,
            mediaIdentifier: "https://cdn.example/video.mkv?token=secret&sig=private#part",
            state: .failed,
            hasVideoOutput: false,
            decodedAudioBuffers: 0,
            lostAudioBuffers: 0,
            decodedVideoFrames: 0,
            lostVideoFrames: 0
        )

        XCTAssertEqual(diagnostic.mediaIdentifier, "https://cdn.example/video.mkv")
        XCTAssertFalse(diagnostic.mediaIdentifier.contains("secret"))
    }

    func testCoordinatorDefersRestoredSeekUntilMatchingReadyAndAppliesOnce() async throws {
        let file = Self.file(id: "episode-restore")
        let engine = DeferredFakeEngine()
        let history = try Self.history(position: 42, accountID: "account-1", fileID: file.fileId)
        let client = ContractFakeClient(resource: PlaybackResource(
            fileID: file.fileId, url: URL(string: "https://example.com/restore.mp4")!,
            cookies: [], requiredHTTPHeaders: [:], expiresAt: nil
        ))
        let coordinator = PlaybackCoordinator(
            client: client, accountID: "account-1", file: file,
            history: history, diagnostics: Diagnostics(), engine: engine
        )

        await coordinator.start()
        XCTAssertEqual(engine.loadGenerations, [1])
        XCTAssertTrue(engine.seekCommands.isEmpty)

        engine.emitReady(generation: 1)
        XCTAssertEqual(engine.seekCommands, [42])

        engine.emitReady(generation: 1)
        XCTAssertEqual(engine.seekCommands, [42])
    }

    func testCoordinatorIgnoresReadyFromStaleGeneration() async throws {
        let first = Self.file(id: "episode-first")
        let second = Self.file(id: "episode-second")
        let engine = DeferredFakeEngine()
        let history = try Self.history(position: 7, accountID: "account-1", fileID: second.fileId)
        let client = ContractFakeClient(resource: PlaybackResource(
            fileID: first.fileId, url: URL(string: "https://example.com/first.mp4")!,
            cookies: [], requiredHTTPHeaders: [:], expiresAt: nil
        ))
        client.resources[second.fileId] = PlaybackResource(
            fileID: second.fileId, url: URL(string: "https://example.com/second.mp4")!,
            cookies: [], requiredHTTPHeaders: [:], expiresAt: nil
        )
        let coordinator = PlaybackCoordinator(
            client: client, accountID: "account-1", file: first, queue: [first, second],
            history: history, diagnostics: Diagnostics(), engine: engine
        )

        await coordinator.start()
        _ = coordinator.playFile(second)
        await Task.yield()
        XCTAssertEqual(engine.loadGenerations, [1, 2])

        engine.emitReady(generation: 1)
        XCTAssertTrue(engine.seekCommands.isEmpty)
        engine.emitReady(generation: 2)
        XCTAssertEqual(engine.seekCommands, [7])
    }

    func testCoordinatorMapsNonFirstActiveTracksByStableIDs() async throws {
        let file = Self.file(id: "episode-tracks")
        let engine = TrackReportingFakeEngine()
        let client = ContractFakeClient(resource: PlaybackResource(
            fileID: file.fileId, url: URL(string: "https://example.com/tracks.mp4")!,
            cookies: [], requiredHTTPHeaders: [:], expiresAt: nil
        ))
        let coordinator = PlaybackCoordinator(
            client: client, accountID: "account-1", file: file,
            history: try Self.history(position: 0, accountID: "account-1", fileID: file.fileId),
            diagnostics: Diagnostics(), engine: engine
        )

        await coordinator.start()

        XCTAssertEqual(coordinator.selectedAudioIndex, 1)
        XCTAssertEqual(coordinator.selectedSubtitleIndex, 1)
    }

    func testCoordinatorRepresentsDisabledSubtitleAsOff() async throws {
        let file = Self.file(id: "episode-subtitles-off")
        let engine = TrackReportingFakeEngine(selectedAudioID: 30, selectedSubtitleID: nil)
        let client = ContractFakeClient(resource: PlaybackResource(
            fileID: file.fileId, url: URL(string: "https://example.com/subtitles-off.mp4")!,
            cookies: [], requiredHTTPHeaders: [:], expiresAt: nil
        ))
        let coordinator = PlaybackCoordinator(
            client: client, accountID: "account-1", file: file,
            history: try Self.history(position: 0, accountID: "account-1", fileID: file.fileId),
            diagnostics: Diagnostics(), engine: engine
        )

        await coordinator.start()

        XCTAssertEqual(coordinator.selectedAudioIndex, 1)
        XCTAssertNil(coordinator.selectedSubtitleIndex)
    }

    private static func file(id: String) -> CloudFile {
        CloudFile(fileId: id, parentId: "root", name: "(id).mp4", size: 1,
                  fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
    }

    private static func history(position: Double, accountID: String, fileID: String) throws -> HistoryRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-playback-contract-\(UUID().uuidString).sqlite")
        let repository = try HistoryRepository(url: url)
        try repository.save(WatchHistory(accountId: accountID, fileId: fileID,
                                         fileName: fileID, positionSeconds: position,
                                         durationSeconds: 120, lastWatchedAt: Date(), completed: false))
        return repository
    }
}

@MainActor
private final class ContractFakeEngine: PlaybackEngine {
    enum Command: Equatable { case play, pause, seek(TimeInterval) }
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var snapshot = PlaybackSnapshot.idle()
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var loadedResource: PlaybackResource?
    var loadedGeneration: Int?
    var emittedGeneration: Int?
    var selectedAudioID: Int?
    var selectedSubtitleID: Int?
    var commands: [Command] = []

    func attachSurface(_ surface: UIView?) {}
    func load(_ resource: PlaybackResource, generation: Int) {
        loadedResource = resource
        loadedGeneration = generation
        snapshot = PlaybackSnapshot(generation: generation, state: .ready, currentTime: 0,
                                    duration: 60, bufferedTime: 0, networkRate: 0, hasVideoOutput: false)
        emittedGeneration = generation
        eventHandler?(.ready(snapshot))
        eventHandler?(.tracksChanged(
            generation: generation,
            audio: [PlaybackTrack(id: 42, kind: .audio, name: "中文", languageCode: "zh", isDisabled: false)],
            subtitles: [PlaybackTrack(id: -1, kind: .subtitle, name: "关闭字幕", languageCode: nil, isDisabled: true)],
            selectedAudioID: 42,
            selectedSubtitleID: nil
        ))
    }
    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() {}
    func seek(to seconds: TimeInterval) { commands.append(.seek(seconds)) }
    func selectAudioTrack(id: Int?) { selectedAudioID = id }
    func selectSubtitleTrack(id: Int?) { selectedSubtitleID = id }
}

@MainActor
private final class DeferredFakeEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var snapshot = PlaybackSnapshot.idle()
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var loadGenerations: [Int] = []
    var seekCommands: [TimeInterval] = []

    func attachSurface(_ surface: UIView?) {}
    func load(_ resource: PlaybackResource, generation: Int) {
        loadGenerations.append(generation)
        snapshot = PlaybackSnapshot(generation: generation, state: .loading,
                                    currentTime: 0, duration: 120, bufferedTime: 0,
                                    networkRate: 0, hasVideoOutput: false)
    }
    func emitReady(generation: Int) {
        snapshot = PlaybackSnapshot(generation: generation, state: .ready,
                                    currentTime: 0, duration: 120, bufferedTime: 0,
                                    networkRate: 0, hasVideoOutput: false)
        eventHandler?(.ready(snapshot))
    }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: TimeInterval) { seekCommands.append(seconds) }
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
}

@MainActor
private final class TrackReportingFakeEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var snapshot = PlaybackSnapshot.idle()
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    let selectedAudioID: Int?
    let selectedSubtitleID: Int?

    init(selectedAudioID: Int? = 30, selectedSubtitleID: Int? = 11) {
        self.selectedAudioID = selectedAudioID
        self.selectedSubtitleID = selectedSubtitleID
    }

    func attachSurface(_ surface: UIView?) {}
    func load(_ resource: PlaybackResource, generation: Int) {
        snapshot = PlaybackSnapshot(generation: generation, state: .ready,
                                    currentTime: 0, duration: 120, bufferedTime: 0,
                                    networkRate: 0, hasVideoOutput: false)
        audioTracks = [
            PlaybackTrack(id: 10, kind: .audio, name: "中文", languageCode: "zh", isDisabled: false),
            PlaybackTrack(id: 30, kind: .audio, name: "English", languageCode: "en", isDisabled: false)
        ]
        subtitleTracks = [
            PlaybackTrack(id: -1, kind: .subtitle, name: "关闭字幕", languageCode: nil, isDisabled: true),
            PlaybackTrack(id: 11, kind: .subtitle, name: "中文", languageCode: "zh", isDisabled: false),
            PlaybackTrack(id: 12, kind: .subtitle, name: "English", languageCode: "en", isDisabled: false)
        ]
        eventHandler?(.ready(snapshot))
        eventHandler?(.tracksChanged(generation: generation, audio: audioTracks, subtitles: subtitleTracks,
                                     selectedAudioID: selectedAudioID, selectedSubtitleID: selectedSubtitleID))
    }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: TimeInterval) {}
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
}

@MainActor
private final class ContractFakeClient: QuarkClient {
    var resources: [String: PlaybackResource]
    init(resource: PlaybackResource) { resources = [resource.fileID: resource] }
    func restoreSession() async throws -> Account? { nil }
    func beginQRCodeLogin() async throws -> QRLoginChallenge { throw QuarkError.mockOnly }
    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { throw QuarkError.mockOnly }
    func cancelQRCodeLogin() {}
    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage { throw QuarkError.mockOnly }
    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage { throw QuarkError.mockOnly }
    func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
        guard let resource = resources[fileID] else { throw QuarkError.invalidResponse("missing resource") }
        return resource
    }
    func logout() async throws {}
}
