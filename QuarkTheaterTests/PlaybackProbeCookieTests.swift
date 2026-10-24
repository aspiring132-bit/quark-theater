import AVFoundation
import XCTest
@testable import QuarkTheater

// Pure cookie filtering tests only. These do not perform playback or claim CDN validation.
final class PlaybackProbeCookieTests: XCTestCase {
    private func cookie(domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "fixture", .value: "not-a-real-cookie", .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testCookieCannotLeakToUnrelatedOrLookalikeDomain() throws {
        let cookies = [cookie(domain: ".quark.cn")]
        XCTAssertEqual(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video"))).count, 1)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://quark.cn.example.net/video"))).isEmpty)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://evilquark.cn/video"))).isEmpty)
    }

    func testHostOnlyCookieIsNotSentToSubdomain() throws {
        let cookies = [cookie(domain: "drive.quark.cn")]
        XCTAssertEqual(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video"))).count, 1)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://cdn.drive.quark.cn/video"))).isEmpty)
    }

    func testCookiePathRequiresSegmentBoundary() throws {
        let cookies = [cookie(domain: ".quark.cn", path: "/video")]
        XCTAssertEqual(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video/file"))).count, 1)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/videos/file"))).isEmpty)
    }

    func testSecureAndExpiredCookiesAreExcluded() throws {
        XCTAssertTrue(PlaybackProbe.applicableCookies([cookie(domain: ".quark.cn")],
            url: try XCTUnwrap(URL(string: "http://drive.quark.cn/video"))).isEmpty)
        XCTAssertTrue(PlaybackProbe.applicableCookies([cookie(domain: ".quark.cn", expires: Date(timeIntervalSince1970: 1))],
            url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video"))).isEmpty)
    }

    func testPlaybackDiagnosticEventRawValuesRemainStable() {
        XCTAssertEqual(DiagnosticEvent.playbackState.rawValue, "playback.state")
        XCTAssertEqual(DiagnosticEvent.playbackError.rawValue, "playback.error")
        XCTAssertEqual(DiagnosticEvent.playbackSeek.rawValue, "playback.seek")
        XCTAssertEqual(DiagnosticEvent.audioSnapshot.rawValue, "audio.snapshot")
        XCTAssertEqual(DiagnosticEvent.audioError.rawValue, "audio.error")
        XCTAssertEqual(DiagnosticEvent.audioInterruptionBegan.rawValue, "audio.interruption_began")
        XCTAssertEqual(DiagnosticEvent.audioInterruptionEnded.rawValue, "audio.interruption_ended")
        XCTAssertEqual(DiagnosticEvent.audioMediaServicesLost.rawValue, "audio.media_services_lost")
        XCTAssertEqual(DiagnosticEvent.audioMediaServicesReset.rawValue, "audio.media_services_reset")
    }

    func testAudioDiagnosticMetadataIsAllowListedAndSanitized() {
        let metadata: [DiagnosticMetadata] = [
            .audioOutputChannels(2),
            .audioInterruptionShouldResume(false), .audioReasonCode(6),
            .audioVolume(0.75), .audioMuted(false), .audioPlaybackRate(1), .audioPlaybackVolume(1)
        ]
        let sanitized = DiagnosticMetadata.sanitizedForTesting(metadata)
        XCTAssertEqual(sanitized["audioOutputChannels"], .int(2))
        XCTAssertEqual(sanitized["audioInterruptionShouldResume"], .bool(false))
        XCTAssertEqual(sanitized["audioReasonCode"], .int(6))
        XCTAssertEqual(sanitized["audioVolume"], .double(0.75))
        XCTAssertEqual(sanitized["audioMuted"], .bool(false))
        XCTAssertFalse(sanitized.keys.contains { $0.lowercased().contains("url") })
    }

    func testAudioSessionCategoryAndModeAreAllowListed() {
        let sanitized = DiagnosticMetadata.sanitizedForTesting([
            .audioSessionCategory(.playback), .audioSessionMode(.moviePlayback)
        ])
        XCTAssertEqual(sanitized["audioSessionCategory"], .string("playback"))
        XCTAssertEqual(sanitized["audioSessionMode"], .string("moviePlayback"))
    }

    func testSeekHUDHidesOnlyAfterQuietPeriod() {
        let interaction = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(PlayerSeekHUDPolicy.shouldHide(now: interaction.addingTimeInterval(2.9), lastInteraction: interaction))
        XCTAssertTrue(PlayerSeekHUDPolicy.shouldHide(now: interaction.addingTimeInterval(3), lastInteraction: interaction))
        XCTAssertFalse(PlayerSeekHUDPolicy.shouldHide(now: interaction.addingTimeInterval(10), lastInteraction: nil))
    }

    func testRepeatedRemoteSeekUsesBoundedAcceleration() {
        XCTAssertEqual(PlayerSeekRepeatPolicy.interval(configured: 10, repeatCount: 0), 10)
        XCTAssertEqual(PlayerSeekRepeatPolicy.interval(configured: 10, repeatCount: 1), 20)
        XCTAssertEqual(PlayerSeekRepeatPolicy.interval(configured: 15, repeatCount: 2), 45)
        XCTAssertEqual(PlayerSeekRepeatPolicy.interval(configured: 15, repeatCount: 9), 60)
    }

    @MainActor
    func testCanceledOrStaleSeekCannotCommitState() {
        let current = UUID()
        XCTAssertTrue(PlaybackCoordinator.shouldCommitSeek(operationToken: current, currentToken: current, playerMatches: true))
        XCTAssertFalse(PlaybackCoordinator.shouldCommitSeek(operationToken: UUID(), currentToken: current, playerMatches: true))
        XCTAssertFalse(PlaybackCoordinator.shouldCommitSeek(operationToken: current, currentToken: current, playerMatches: false))
        XCTAssertFalse(PlaybackCoordinator.shouldCommitSeek(operationToken: current, currentToken: current, playerMatches: true, isCancelled: true))
    }

    @MainActor
    func testStaleSeekCompletionCannotClearReplacementSeekState() {
        let stale = UUID()
        let current = UUID()
        XCTAssertFalse(PlaybackCoordinator.shouldClearSeekState(
            operationToken: stale, currentToken: current, playerMatches: false, isCancelled: false
        ))
        XCTAssertTrue(PlaybackCoordinator.shouldClearSeekState(
            operationToken: current, currentToken: current, playerMatches: true, isCancelled: false
        ))
    }

    @MainActor
    func testRetrySchedulingIsDeduplicatedPerPlaybackGeneration() {
        XCTAssertTrue(PlaybackCoordinator.shouldScheduleRetry(
            currentGeneration: 4, scheduledGeneration: nil, retryTaskActive: false
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldScheduleRetry(
            currentGeneration: 4, scheduledGeneration: 4, retryTaskActive: true
        ))
        XCTAssertTrue(PlaybackCoordinator.shouldScheduleRetry(
            currentGeneration: 5, scheduledGeneration: 4, retryTaskActive: true
        ))
        XCTAssertTrue(PlaybackCoordinator.shouldScheduleRetry(
            currentGeneration: 4, scheduledGeneration: 4, retryTaskActive: false
        ))
    }

    @MainActor
    func testCookieHeaderIsExcludedFromVLCResourceOptions() {
        let headers = ["Cookie": "a=b", "User-Agent": "fixture"]
        let filtered = PlaybackCoordinator.headersExcludingCookie(headers)
        XCTAssertNil(filtered["Cookie"])
        XCTAssertEqual(filtered["User-Agent"], "fixture")
    }

    func testPlaybackDiagnosticsExposeEngineAndAVSyncWithoutSensitiveIdentity() {
        let metadata: [DiagnosticMetadata] = [
            .playerEngine(.vlcPlayer), .avSyncDeltaMilliseconds(-42), .droppedFrames(3),
            .focusOrdinal(2), .episodeOrdinal(4)
        ]
        let sanitized = DiagnosticMetadata.sanitizedForTesting(metadata)
        XCTAssertEqual(sanitized["playerEngine"], .string("vlc_player"))
        XCTAssertEqual(sanitized["avSyncDeltaMs"], .double(-42))
        XCTAssertEqual(sanitized["droppedFrames"], .int(3))
        XCTAssertEqual(sanitized["focusOrdinal"], .int(2))
        XCTAssertEqual(sanitized["episodeOrdinal"], .int(4))
        XCTAssertFalse(sanitized.keys.contains { $0.lowercased().contains("file") })
        XCTAssertFalse(sanitized.keys.contains { $0.lowercased().contains("url") })
    }

    @MainActor
    func testPlaybackHeartbeatEligibilityIsBoundedAndStateDriven() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(PlaybackCoordinator.shouldEmitPlaybackHeartbeat(
            now: t0.addingTimeInterval(14), lastSampleDate: t0,
            state: .playing, lastState: .playing,
            audioTrackChanged: false, audioRouteChanged: false
        ))
        XCTAssertTrue(PlaybackCoordinator.shouldEmitPlaybackHeartbeat(
            now: t0.addingTimeInterval(15), lastSampleDate: t0,
            state: .playing, lastState: .playing,
            audioTrackChanged: false, audioRouteChanged: false
        ))
        XCTAssertTrue(PlaybackCoordinator.shouldEmitPlaybackHeartbeat(
            now: t0.addingTimeInterval(1), lastSampleDate: t0,
            state: .playing, lastState: .playing,
            audioTrackChanged: true, audioRouteChanged: false
        ))
        XCTAssertTrue(PlaybackCoordinator.shouldEmitPlaybackHeartbeat(
            now: t0.addingTimeInterval(1), lastSampleDate: t0,
            state: .paused, lastState: .playing,
            audioTrackChanged: false, audioRouteChanged: false
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldEmitPlaybackHeartbeat(
            now: t0.addingTimeInterval(60), lastSampleDate: t0,
            state: .paused, lastState: .paused,
            audioTrackChanged: false, audioRouteChanged: false
        ))
    }

    @MainActor
    func testPlaybackHeartbeatStartIsIdempotentWhileTaskIsActive() {
        XCTAssertFalse(PlaybackCoordinator.shouldKeepExistingPlaybackHeartbeat(isTaskActive: false))
        XCTAssertTrue(PlaybackCoordinator.shouldKeepExistingPlaybackHeartbeat(isTaskActive: true))
    }

    @MainActor
    func testPlaybackSessionTransitionResetsHeartbeatOnlyForMountedPlayer() {
        XCTAssertTrue(PlaybackCoordinator.shouldResetPlaybackHeartbeatForSessionTransition(hasActivePlayer: true))
        XCTAssertFalse(PlaybackCoordinator.shouldResetPlaybackHeartbeatForSessionTransition(hasActivePlayer: false))
    }

    @MainActor
    func testQueuedObserverCallbackCannotMutateReplacementPlayback() {
        let oldItem = AVPlayerItem(url: URL(string: "https://example.invalid/old.m3u8")!)
        let newItem = AVPlayerItem(url: URL(string: "https://example.invalid/new.m3u8")!)
        let oldPlayer = AVPlayer(playerItem: oldItem)
        let newPlayer = AVPlayer(playerItem: newItem)

        XCTAssertTrue(PlaybackCoordinator.observerBelongsToCurrentPlayback(
            observedPlayer: oldPlayer,
            observedItem: oldItem,
            currentPlayer: oldPlayer,
            currentItem: oldItem
        ))
        XCTAssertFalse(PlaybackCoordinator.observerBelongsToCurrentPlayback(
            observedPlayer: oldPlayer,
            observedItem: oldItem,
            currentPlayer: newPlayer,
            currentItem: newItem
        ))
        XCTAssertFalse(PlaybackCoordinator.observerBelongsToCurrentPlayback(
            observedPlayer: oldPlayer,
            observedItem: oldItem,
            currentPlayer: oldPlayer,
            currentItem: newItem
        ))
    }

    @MainActor
    func testSilentMarkerPersistsSanitizedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-playback-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let file = CloudFile(fileId: "video-1", parentId: "root", name: "private-title.mkv",
                             size: 1, fileExtension: "mkv", modifiedAt: nil, isDirectory: false)
        let coordinator = PlaybackCoordinator(
            client: MockQuarkClient(), accountID: "account-1", file: file,
            history: history, diagnostics: diagnostics
        )

        coordinator.markSilent()
        await diagnostics.waitForPendingOperations()

        XCTAssertEqual(diagnostics.records.first?.event, .silentMarker)
        XCTAssertEqual(diagnostics.records.first?.category, .audio)
        XCTAssertNil(diagnostics.records.first?.metadata["fileName"])
        XCTAssertNil(diagnostics.records.first?.metadata["url"])
    }
}
