import XCTest
@testable import QuarkTheater

final class FocusNavigationTests: XCTestCase {
    func testBackFromNonMediaAlwaysReturnsToMedia() {
        XCTAssertEqual(RootFocusReducer.selectedTabAfterBack(.sources), .media)
        XCTAssertEqual(RootFocusReducer.selectedTabAfterBack(.settings), .media)
        XCTAssertTrue(RootFocusReducer.shouldConsumeBack(.sources))
        XCTAssertTrue(RootFocusReducer.shouldConsumeBack(.settings))
    }

    func testBackOnMediaIsNotConsumed() {
        XCTAssertEqual(RootFocusReducer.selectedTabAfterBack(.media), .media)
        XCTAssertFalse(RootFocusReducer.shouldConsumeBack(.media))
    }

    func testDockTargetFollowsSelectedTab() {
        for tab in RootTab.allCases {
            XCTAssertEqual(RootFocusReducer.dockTarget(for: tab), tab)
        }
    }

    func testFocusTargetsCollapseViewLocalIdentifiersIntoCoarseRegions() {
        XCTAssertEqual(FocusDiagnostics.target(for: FileBrowserFocusTarget.file("secret-file")), .fileBrowserRow)
        XCTAssertEqual(FocusDiagnostics.target(for: FolderFocusTarget.folderEnter("secret-folder")), .folderRow)
        XCTAssertEqual(FocusDiagnostics.target(for: PlayerFocusTarget.episode("secret-file")), .playerEpisode)
        XCTAssertEqual(FocusDiagnostics.historyTarget, .historyRow)
        XCTAssertEqual(FocusDiagnostics.tmdbTarget, .tmdbResult)
    }

    func testLibraryActionTargetsAreUnique() {
        let targets: [LibraryFocusTarget] = [
            .heroDetails, .heroPlay, .heroRematch, .episode("file-1"), .episode("file-2"),
            .filter("all"), .filter("movie"), .filter("series")
        ]
        XCTAssertEqual(Set(targets).count, targets.count)
    }

    func testFolderSelectionTargetsKeepSelectAndEnterDistinct() {
        let targets: [FolderFocusTarget] = [
            .folderSelect("folder-1"), .folderEnter("folder-1"),
            .folderSelect("folder-2"), .folderEnter("folder-2"),
            .breadcrumb(0), .breadcrumb(1), .cancel
        ]
        XCTAssertEqual(Set(targets).count, targets.count)
        XCTAssertNotEqual(FolderFocusTarget.folderSelect("folder-1"),
                          FolderFocusTarget.folderEnter("folder-1"))
    }

    func testBackHandlerIsOnlyInstalledOutsideMedia() {
        XCTAssertFalse(RootFocusReducer.shouldConsumeBack(.media))
        XCTAssertTrue(RootFocusReducer.shouldConsumeBack(.settings))
    }

    func testSeekMathClampsAndNormalizesIntervals() {
        XCTAssertEqual(PlayerSeekMath.normalizedInterval(15), 15)
        XCTAssertEqual(PlayerSeekMath.normalizedInterval(12), 10)
        XCTAssertEqual(PlayerSeekMath.target(current: 20, direction: .backward, interval: 10, duration: 100), 10)
        XCTAssertEqual(PlayerSeekMath.target(current: 5, direction: .backward, interval: 15, duration: 100), 0)
        XCTAssertEqual(PlayerSeekMath.target(current: 95, direction: .forward, interval: 15, duration: 100), 100)
        XCTAssertNil(PlayerSeekMath.target(current: .infinity, direction: .forward, interval: 10, duration: 100))
        XCTAssertEqual(PlayerSeekMath.target(current: 5, direction: .forward, interval: 10, duration: nil), 15)
        XCTAssertEqual(PlayerSeekMath.nextTarget(current: 10, pending: nil, inFlight: 20, direction: .forward, interval: 10, duration: 100), 30)
        XCTAssertEqual(PlayerSeekMath.nextTarget(current: 10, pending: 20, inFlight: 30, direction: .forward, interval: 10, duration: 100), 30)
    }

    func testDiagnosticProjectionFiltersNewestFirstAndHandlesEmpty() {
        let session = UUID()
        let older = DiagnosticRecord(date: Date(timeIntervalSince1970: 10), sessionID: session,
                                     category: .audio, level: .info, event: .started)
        let newer = DiagnosticRecord(date: Date(timeIntervalSince1970: 20), sessionID: session,
                                     category: .cloud, level: .warning, event: .requestFailed)
        let records = DiagnosticRecordProjection.visible([older, newer], category: nil)
        XCTAssertEqual(records.map(\.id), [newer.id, older.id])
        XCTAssertEqual(DiagnosticRecordProjection.visible([older, newer], category: .audio).map(\.id), [older.id])
        XCTAssertTrue(DiagnosticRecordProjection.visible([], category: .audio).isEmpty)
    }

    func testPlayerFocusTargetsAreUnique() {
        let targets: [PlayerFocusTarget] = [.drawerTab("episodes"), .drawerTab("audio"), .closeDrawer,
                                             .silentMarker, .nextEpisode, .episode("1"), .subtitle("1"), .audio("1")]
        XCTAssertEqual(Set(targets).count, targets.count)
    }

    func testHistoryDeletionFocusChoosesSuccessorThenPredecessor() {
        let records = [
            WatchHistory(accountId: "acct", fileId: "a", fileName: "A", positionSeconds: 0, durationSeconds: 1, lastWatchedAt: .distantPast, completed: false),
            WatchHistory(accountId: "acct", fileId: "b", fileName: "B", positionSeconds: 0, durationSeconds: 1, lastWatchedAt: .distantPast, completed: false),
            WatchHistory(accountId: "acct", fileId: "c", fileName: "C", positionSeconds: 0, durationSeconds: 1, lastWatchedAt: .distantPast, completed: false)
        ]
        XCTAssertEqual(HistoryFocusReducer.successor(after: "a", in: records), "b")
        XCTAssertEqual(HistoryFocusReducer.successor(after: "b", in: records), "c")
        XCTAssertEqual(HistoryFocusReducer.successor(after: "c", in: records), "b")
        XCTAssertNil(HistoryFocusReducer.successor(after: "a", in: [records[0]]))
    }
}
