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
    func testKSPlayerFinishOnlyRetriesWhenCallbackCarriesError() {
        XCTAssertTrue(PlaybackCoordinator.shouldTreatKSFinishAsFailure(NSError(domain: "test", code: 1)))
        XCTAssertFalse(PlaybackCoordinator.shouldTreatKSFinishAsFailure(nil))
    }

    @MainActor
    func testKSPlayerCookieHeaderIsProvidedOnlyThroughSetCookie() {
        let headers = ["Cookie": "a=b", "User-Agent": "fixture"]
        let filtered = PlaybackCoordinator.headersExcludingCookie(headers)
        XCTAssertNil(filtered["Cookie"])
        XCTAssertEqual(filtered["User-Agent"], "fixture")
    }

    @MainActor
    func testKSPlayerTrackSnapshotOnlyChangesWhenTracksOrSelectionChanges() {
        XCTAssertTrue(PlaybackCoordinator.ksTrackSnapshotChanged(previousIDs: [], currentIDs: [1], previousSelected: nil, currentSelected: nil))
        XCTAssertFalse(PlaybackCoordinator.ksTrackSnapshotChanged(previousIDs: [1], currentIDs: [1], previousSelected: nil, currentSelected: nil))
        XCTAssertTrue(PlaybackCoordinator.ksTrackSnapshotChanged(previousIDs: [1], currentIDs: [1], previousSelected: nil, currentSelected: 0))
    }

    @MainActor
    func testKSSubtitleSelectionOffDoesNotFallBackToEmbeddedTrack() {
        XCTAssertNil(PlaybackCoordinator.ksSubtitleSelectionIndex(
            infoIDs: ["zh"], selectedID: nil, trackFallback: 0
        ))
        XCTAssertEqual(PlaybackCoordinator.ksSubtitleSelectionIndex(
            infoIDs: [], selectedID: nil, trackFallback: 0
        ), 0)
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
