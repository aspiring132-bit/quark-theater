#if canImport(TVVLCKit)
import UIKit
import XCTest
@testable import QuarkTheater

@MainActor
final class VLCPlaybackControllerTests: XCTestCase {
    func testMapsVLCStateRawValuesToObservableState() {
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 0), .idle)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 1), .loading)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 2), .buffering)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 3), .ended)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 4), .failed)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 5), .playing)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 6), .paused)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 7), .loading)
        XCTAssertEqual(VLCPlaybackStateMapper.map(rawValue: 99), .failed)
    }

    func testMapsObservableStateToEngineState() {
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .idle), .idle)
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .loading), .loading)
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .buffering), .buffering)
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .playing), .playing)
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .paused), .paused)
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .ended), .ended)
        XCTAssertEqual(VLCPlaybackStateMapper.engineState(for: .failed), .failed)
    }

    func testProcessDiscoveredAudioTracksFiltersSyntheticDisabledAndPreservesRealTracks() {
        let ids = [-1, 1, 2]
        let names = ["Disabled", "Audio Track 1 - Chinese", "Audio Track 2 - English"]
        let languages = [1: "zh", 2: "en"]

        let tracks = VLCPlaybackController.processDiscoveredAudioTracks(
            ids: ids,
            names: names,
            languages: languages
        )

        // Must NOT contain synthetic disabled audio item
        XCTAssertEqual(tracks.count, 2)
        XCTAssertFalse(tracks.contains { $0.isDisabled })
        XCTAssertEqual(tracks[0].id, 1)
        XCTAssertEqual(tracks[0].name, "Audio Track 1 - Chinese")
        XCTAssertEqual(tracks[0].languageCode, "zh")
        XCTAssertEqual(tracks[0].kind, .audio)
        XCTAssertFalse(tracks[0].isDisabled)

        XCTAssertEqual(tracks[1].id, 2)
        XCTAssertEqual(tracks[1].name, "Audio Track 2 - English")
        XCTAssertEqual(tracks[1].languageCode, "en")
        XCTAssertEqual(tracks[1].kind, .audio)
        XCTAssertFalse(tracks[1].isDisabled)
    }

    func testProcessDiscoveredSubtitleTracksPrependsDisabledRowAndFiltersVLCDisabledRow() {
        let ids = [-1, 1, 3]
        let names = ["Disable", "Chinese Subtitles", "English Subtitles"]
        let languages = [1: "zh", 3: "en"]

        let tracks = VLCPlaybackController.processDiscoveredSubtitleTracks(
            ids: ids,
            names: names,
            languages: languages
        )

        // Must start with standard disabled row "关闭字幕", followed by real subtitle tracks
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[0].id, -1)
        XCTAssertEqual(tracks[0].name, "关闭字幕")
        XCTAssertNil(tracks[0].languageCode)
        XCTAssertTrue(tracks[0].isDisabled)
        XCTAssertEqual(tracks[0].kind, .subtitle)

        XCTAssertEqual(tracks[1].id, 1)
        XCTAssertEqual(tracks[1].name, "Chinese Subtitles")
        XCTAssertEqual(tracks[1].languageCode, "zh")
        XCTAssertFalse(tracks[1].isDisabled)

        XCTAssertEqual(tracks[2].id, 3)
        XCTAssertEqual(tracks[2].name, "English Subtitles")
        XCTAssertEqual(tracks[2].languageCode, "en")
        XCTAssertFalse(tracks[2].isDisabled)
    }

    func testIsDisabledNameIdentifiesDisabledAliases() {
        XCTAssertTrue(VLCPlaybackController.isDisabledName("Disabled"))
        XCTAssertTrue(VLCPlaybackController.isDisabledName("disabled"))
        XCTAssertTrue(VLCPlaybackController.isDisabledName("Disable"))
        XCTAssertTrue(VLCPlaybackController.isDisabledName("disable"))
        XCTAssertTrue(VLCPlaybackController.isDisabledName("关闭字幕"))
        XCTAssertTrue(VLCPlaybackController.isDisabledName("关闭"))
        XCTAssertTrue(VLCPlaybackController.isDisabledName("  Disabled  "))

        XCTAssertFalse(VLCPlaybackController.isDisabledName("English"))
        XCTAssertFalse(VLCPlaybackController.isDisabledName("Track 1"))
        XCTAssertFalse(VLCPlaybackController.isDisabledName("Mandarin 5.1"))
    }

    func testActiveTrackIDMapsVLCDisabledSentinelToNil() {
        XCTAssertEqual(VLCPlaybackController.activeTrackID(23), 23)
        XCTAssertNil(VLCPlaybackController.activeTrackID(-1))
    }

    func testControllerImplementsPlaybackEngineAndInitialState() {
        let controller = VLCPlaybackController()

        // Protocol conformity check
        let engine: PlaybackEngine = controller
        XCTAssertEqual(engine.snapshot, PlaybackSnapshot.idle())
        XCTAssertTrue(engine.audioTracks.isEmpty)
        XCTAssertTrue(engine.subtitleTracks.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.currentTimeSeconds, 0)
        XCTAssertEqual(controller.durationSeconds, 0)
        XCTAssertFalse(controller.hasVideoOutput)
        XCTAssertFalse(controller.isSeekable)
    }

    func testLoadUpdatesGenerationAndEmitsLoadingSnapshot() {
        let controller = VLCPlaybackController()
        var emittedEvents: [PlaybackEngineEvent] = []
        controller.eventHandler = { emittedEvents.append($0) }

        let resource = PlaybackResource(
            fileID: "fixture-file-42",
            url: URL(string: "https://example.com/video.mp4?token=secret123")!,
            cookies: [],
            requiredHTTPHeaders: ["User-Agent": "TestEngine/1.0"],
            expiresAt: nil
        )

        controller.load(resource, generation: 42)

        XCTAssertEqual(controller.snapshot.generation, 42)
        XCTAssertEqual(controller.snapshot.state, .loading)
        XCTAssertFalse(emittedEvents.isEmpty)
        XCTAssertEqual(emittedEvents.first?.generation, 42)

        if case .stateChanged(let snapshot) = emittedEvents.first {
            XCTAssertEqual(snapshot.generation, 42)
            XCTAssertEqual(snapshot.state, .loading)
        } else {
            XCTFail("Expected .stateChanged event upon load")
        }
    }

    func testStopResetsStateAndIncrementsGeneration() {
        let controller = VLCPlaybackController()
        let resource = PlaybackResource(
            fileID: "fixture-file",
            url: URL(string: "https://example.com/video.mp4")!,
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )

        controller.load(resource, generation: 10)
        controller.stop()

        XCTAssertEqual(controller.snapshot.state, .idle)
        XCTAssertTrue(controller.audioTracks.isEmpty)
        XCTAssertTrue(controller.subtitleTracks.isEmpty)
        XCTAssertEqual(controller.snapshot.generation, 11)
    }

    func testAttachSurfaceAcceptsViews() {
        let controller = VLCPlaybackController()
        let surfaceView = UIView()

        controller.attachSurface(surfaceView)
        controller.attachSurface(nil)
    }

    func testStaleNotificationRejection() {
        let controller = VLCPlaybackController()
        var emittedEvents: [PlaybackEngineEvent] = []
        controller.eventHandler = { emittedEvents.append($0) }

        // A notification originating from an unknown/unrelated object ID must be discarded
        let unrelatedObjectID = ObjectIdentifier(UIView())
        controller.handleMediaPlayerStateChanged(notifyingObjectID: unrelatedObjectID)
        controller.handleMediaPlayerTimeChanged(notifyingObjectID: unrelatedObjectID)

        XCTAssertTrue(emittedEvents.isEmpty)
        XCTAssertEqual(controller.snapshot.state, .idle)
    }

    func testDiagnosticSnapshotRedactsSignedURLParameters() {
        let diagnostic = PlaybackDiagnosticSnapshot(
            generation: 15,
            mediaIdentifier: "https://cdn.quark.cn/video.mp4?auth_key=123456&token=abcdef#segment1",
            state: .buffering,
            hasVideoOutput: true,
            decodedAudioBuffers: 100,
            lostAudioBuffers: 2,
            decodedVideoFrames: 250,
            lostVideoFrames: 1
        )

        XCTAssertEqual(diagnostic.generation, 15)
        XCTAssertEqual(diagnostic.mediaIdentifier, "https://cdn.quark.cn/video.mp4")
        XCTAssertFalse(diagnostic.mediaIdentifier.contains("auth_key"))
        XCTAssertFalse(diagnostic.mediaIdentifier.contains("token"))
        XCTAssertFalse(diagnostic.mediaIdentifier.contains("segment1"))
        XCTAssertEqual(diagnostic.decodedAudioBuffers, 100)
        XCTAssertEqual(diagnostic.lostAudioBuffers, 2)
        XCTAssertEqual(diagnostic.decodedVideoFrames, 250)
        XCTAssertEqual(diagnostic.lostVideoFrames, 1)
        XCTAssertTrue(diagnostic.hasVideoOutput)
    }

    func testPlaybackSnapshotPreservesEmptyRangesWithoutSynthesizingFromBufferedTime() {
        let snapshot = PlaybackSnapshot(
            generation: 1,
            state: .playing,
            currentTime: 10,
            duration: 100,
            bufferedTime: 30,
            networkRate: 1000,
            hasVideoOutput: true,
            bufferedRanges: []
        )

        XCTAssertEqual(snapshot.bufferedTime, 30)
        XCTAssertEqual(snapshot.bufferedRanges, [])
    }
}
#endif
