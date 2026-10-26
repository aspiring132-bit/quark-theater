import XCTest
@testable import QuarkTheater

final class FocusNavigationTests: XCTestCase {
    func testCanvasPreviewUsesStaticPlayerSurfaceWithoutStartingPlayback() {
        XCTAssertFalse(PlayerCanvasPreviewPolicy.shouldStartPlayback(isCanvasPreview: true))
        XCTAssertTrue(PlayerCanvasPreviewPolicy.shouldShowStaticSurface(isCanvasPreview: true))
        XCTAssertTrue(PlayerCanvasPreviewPolicy.shouldOpenDrawerInitially(isCanvasPreview: true))
        XCTAssertTrue(PlayerCanvasPreviewPolicy.shouldStartPlayback(isCanvasPreview: false))
        XCTAssertFalse(PlayerCanvasPreviewPolicy.shouldShowStaticSurface(isCanvasPreview: false))
    }

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
        XCTAssertEqual(PlayerSeekMath.normalizedInterval(10), 10)
        XCTAssertEqual(PlayerSeekMath.normalizedInterval(12), 10)
        XCTAssertEqual(PlayerSeekMath.target(current: 20, direction: .backward, interval: 10, duration: 100), 10)
        XCTAssertEqual(PlayerSeekMath.target(current: 5, direction: .backward, interval: 15, duration: 100), 0)
        XCTAssertEqual(PlayerSeekMath.target(current: 95, direction: .forward, interval: 15, duration: 100), 100)
        XCTAssertNil(PlayerSeekMath.target(current: .infinity, direction: .forward, interval: 10, duration: 100))
        XCTAssertEqual(PlayerSeekMath.target(current: 5, direction: .forward, interval: 10, duration: nil), 15)
        XCTAssertEqual(PlayerSeekMath.nextTarget(current: 10, pending: nil, inFlight: 20, direction: .forward, interval: 10, duration: 100), 30)
        XCTAssertEqual(PlayerSeekMath.nextTarget(current: 10, pending: 20, inFlight: 30, direction: .forward, interval: 10, duration: 100), 30)
    }

    func testSeekMathPreservesRepeatedIntervalsAndBounds() {
        // Regression tests: repeated intervals (20/30/40 and 30/45/60) must not collapse to 10
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .forward, interval: 20, duration: 1000), 120)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .forward, interval: 30, duration: 1000), 130)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .forward, interval: 40, duration: 1000), 140)

        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .forward, interval: 30, duration: 1000), 130)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .forward, interval: 45, duration: 1000), 145)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .forward, interval: 60, duration: 1000), 160)

        // Backward repeated intervals
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .backward, interval: 20, duration: 1000), 80)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .backward, interval: 30, duration: 1000), 70)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .backward, interval: 40, duration: 1000), 60)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .backward, interval: 45, duration: 1000), 55)
        XCTAssertEqual(PlayerSeekMath.target(current: 100, direction: .backward, interval: 60, duration: 1000), 40)

        // Boundary and cap tests
        // Clamping to duration cap
        XCTAssertEqual(PlayerSeekMath.target(current: 980, direction: .forward, interval: 40, duration: 1000), 1000)
        XCTAssertEqual(PlayerSeekMath.target(current: 980, direction: .forward, interval: 60, duration: 1000), 1000)
        // Clamping to 0 lower boundary
        XCTAssertEqual(PlayerSeekMath.target(current: 25, direction: .backward, interval: 30, duration: 1000), 0)
        XCTAssertEqual(PlayerSeekMath.target(current: 25, direction: .backward, interval: 60, duration: 1000), 0)
        // Invalid current position
        XCTAssertNil(PlayerSeekMath.target(current: -1, direction: .forward, interval: 20, duration: 1000))
        XCTAssertNil(PlayerSeekMath.target(current: .nan, direction: .forward, interval: 20, duration: 1000))
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

    func testFolderBindingBackdropStyleBlursAndDimsWhenPresented() {
        XCTAssertGreaterThanOrEqual(FolderBindingBackdropStyle.blur(isPresented: true), 20)
        XCTAssertGreaterThanOrEqual(FolderBindingBackdropStyle.dimming(isPresented: true), 0.7)
    }

    func testFolderBindingBackdropStyleIsClearWhenDismissed() {
        XCTAssertEqual(FolderBindingBackdropStyle.blur(isPresented: false), 0)
        XCTAssertEqual(FolderBindingBackdropStyle.dimming(isPresented: false), 0)
    }

    func testDrawerButtonFocusStyleScaling() {
        XCTAssertEqual(DrawerButtonFocusStyle.scale(isFocused: false), 1.0)
        XCTAssertGreaterThan(DrawerButtonFocusStyle.scale(isFocused: true), 1.0)
        XCTAssertEqual(DrawerButtonFocusStyle.scale(isFocused: true), 1.06, accuracy: 0.02)
        XCTAssertTrue(DrawerButtonFocusStyle.prefersPlainButtonStyle)
    }

    // MARK: - Drawer Navigation & Audio Tab Tests
    func testDrawerBackDuplicateAndLateTransitionNeverDismissesPlayer() {
        // Reproduction scenario:
        // In Apple TV 4K tvOS simulator, playing 大西洋帝国 S1E2 (episode "boardwalk-s1e2").
        // Drawer is visibly open on the Episodes tab ("选集").
        // Focus is on current playing episode card.
        let t0 = Date(timeIntervalSinceReferenceDate: 1000.0)

        let initialDrawerState = PlayerBackTransitionState(
            isDrawerOpen: true,
            lastDrawerCloseDate: nil,
            lastBackDate: nil,
            focusedTarget: .episode("boardwalk-s1e2")
        )

        // 1. Initial Device Hub Back press at t0: Must close only the drawer.
        let initialDisposition = PlayerBackTransitionReducer.evaluate(state: initialDrawerState, at: t0)
        XCTAssertEqual(initialDisposition, .closeDrawer, "First Back press while drawer is open must only close drawer")
        XCTAssertEqual(initialDisposition.diagnosticDisposition, .closedDrawer)

        // 2. Drawer closes: showDrawer becomes false, lastDrawerCloseDate recorded as t0, lastBackDate recorded as t0.
        // During spring animation / transit, focus on drawer is cleared (nil) or in transit to drawerTrigger.
        let closingTransitState = PlayerBackTransitionState(
            isDrawerOpen: false,
            lastDrawerCloseDate: t0,
            lastBackDate: t0,
            focusedTarget: nil
        )

        // Rapid duplicate press (<0.35s / 0.20s): must be ignored.
        let rapidDuplicateDisposition = PlayerBackTransitionReducer.evaluate(
            state: closingTransitState,
            at: t0.addingTimeInterval(0.20)
        )
        XCTAssertEqual(rapidDuplicateDisposition, .ignore, "Rapid duplicate event must be ignored")
        XCTAssertEqual(rapidDuplicateDisposition.diagnosticDisposition, .ignored)

        // 3. Late duplicate / trailing release event at 0.50s (typical simulator click duration or late button release):
        // Previously failed with .dismissPlayer because 0.50s > 0.35s duplicate guard and > 0.45s cooldown!
        let lateDuplicateState = PlayerBackTransitionState(
            isDrawerOpen: false,
            lastDrawerCloseDate: t0,
            lastBackDate: t0,
            focusedTarget: .drawerTrigger
        )
        let lateDuplicateDisposition = PlayerBackTransitionReducer.evaluate(
            state: lateDuplicateState,
            at: t0.addingTimeInterval(0.50)
        )
        XCTAssertEqual(
            lateDuplicateDisposition,
            .ignore,
            "Late duplicate back event at 0.50s from single Back press must be ignored, not dismiss player"
        )
        XCTAssertEqual(
            lateDuplicateDisposition.diagnosticDisposition,
            .ignored,
            "Screen log must record .ignored, never .dismissedPlayer for late duplicate event"
        )

        // 4. Another trailing event at 0.70s during spring settling: must be ignored.
        let settlingDisposition = PlayerBackTransitionReducer.evaluate(
            state: lateDuplicateState,
            at: t0.addingTimeInterval(0.70)
        )
        XCTAssertEqual(settlingDisposition, .ignore, "Back event during drawer settling window (0.70s) must be ignored")
        XCTAssertEqual(settlingDisposition.diagnosticDisposition, .ignored)

        // 5. While focus is in transit (nil) following drawer close, must never dismiss.
        let transitAt050Disposition = PlayerBackTransitionReducer.evaluate(
            state: closingTransitState,
            at: t0.addingTimeInterval(0.50)
        )
        XCTAssertEqual(transitAt050Disposition, .ignore, "Back while focus is in transit must be ignored")

        // A held/repeated or delayed event from the same Back action must not
        // dismiss playback after the drawer has just closed.
        let delayedRepeatState = PlayerBackTransitionState(
            isDrawerOpen: false,
            lastDrawerCloseDate: t0,
            lastBackDate: t0,
            focusedTarget: .drawerTrigger
        )
        XCTAssertEqual(
            PlayerBackTransitionReducer.evaluate(state: delayedRepeatState, at: t0.addingTimeInterval(1.50)),
            .ignore,
            "A delayed/repeated Back event within the drawer-close guard must leave the player open"
        )

        // 6. Deliberate subsequent Back press after the guard (3.10s):
        // Drawer is closed, focus is stably on playback (.drawerTrigger), cooldown elapsed.
        let playbackState = PlayerBackTransitionState(
            isDrawerOpen: false,
            lastDrawerCloseDate: t0,
            lastBackDate: t0,
            focusedTarget: .drawerTrigger
        )
        let playbackDisposition = PlayerBackTransitionReducer.evaluate(
            state: playbackState,
            at: t0.addingTimeInterval(3.10)
        )
        XCTAssertEqual(playbackDisposition, .dismissPlayer, "Deliberate Back press on playback surface must dismiss player")
        XCTAssertEqual(playbackDisposition.diagnosticDisposition, .dismissedPlayer)
    }

    func testDrawerBackOnlyClosesDrawerAndNeverDismissesPlayer() {
        var state = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .episode("f1"),
            canPlayNext: true,
            currentPlaybackTime: 10,
            duration: 100,
            episodeFileIDs: ["f1", "f2"],
            currentEpisodeFileID: "f1"
        )
        let action = PlayerInputReducer.handleBack(state: state)
        XCTAssertEqual(action, .closeDrawer, "Back key when drawer is open MUST only close drawer, never dismiss player")

        state.isDrawerOpen = false
        let closedAction = PlayerInputReducer.handleBack(state: state)
        XCTAssertEqual(closedAction, .none, "Back key when drawer is closed returns none (allowing player screen to dismiss)")
    }

    func testDrawerBackHandlesAllTabsAndContentLevelsConsistently() {
        let tabs = ["选集", "字幕", "音轨"]
        let contentTargets: [PlayerFocusTarget] = [
            .episode("f1"),
            .nextEpisode,
            .subtitle("off"),
            .subtitle("0"),
            .audio("0")
        ]
        let tabTargets: [PlayerFocusTarget] = [
            .drawerTab("选集"),
            .drawerTab("字幕"),
            .drawerTab("音轨")
        ]

        // 1. Across all drawer tabs and tab targets: when drawer is open, back returns .closeDrawer
        for tab in tabs {
            for target in tabTargets {
                let state = PlayerInputState(
                    isDrawerOpen: true,
                    selectedDrawerTab: tab,
                    focusedTarget: target,
                    canPlayNext: true,
                    currentPlaybackTime: 10,
                    duration: 100,
                    episodeFileIDs: ["f1", "f2"],
                    currentEpisodeFileID: "f1"
                )
                XCTAssertEqual(
                    PlayerInputReducer.handleBack(state: state),
                    .closeDrawer,
                    "Back from tab \(target) on \(tab) tab must return closeDrawer"
                )
            }
        }

        // 2. Across all content targets: when drawer is open, back returns .closeDrawer
        for tab in tabs {
            for target in contentTargets {
                let state = PlayerInputState(
                    isDrawerOpen: true,
                    selectedDrawerTab: tab,
                    focusedTarget: target,
                    canPlayNext: true,
                    currentPlaybackTime: 10,
                    duration: 100,
                    episodeFileIDs: ["f1", "f2"],
                    currentEpisodeFileID: "f1"
                )
                XCTAssertEqual(
                    PlayerInputReducer.handleBack(state: state),
                    .closeDrawer,
                    "Back from content \(target) on \(tab) tab must return closeDrawer"
                )
            }
        }

        // 3. When drawer is closed, back returns .none so subsequent back dismisses player
        for target in contentTargets + tabTargets + [.drawerTrigger, .skipIntro, .skipOutro] {
            let state = PlayerInputState(
                isDrawerOpen: false,
                selectedDrawerTab: "选集",
                focusedTarget: target,
                canPlayNext: true,
                currentPlaybackTime: 10,
                duration: 100,
                episodeFileIDs: ["f1", "f2"],
                currentEpisodeFileID: "f1"
            )
            XCTAssertEqual(
                PlayerInputReducer.handleBack(state: state),
                .none,
                "Back when drawer is closed on \(target) must return .none allowing dismissal"
            )
        }
    }

    func testAudioTabDefaultTargetWhenNoTracksPointsToTabNotSilentMarker() {
        let target = PlayerInputReducer.defaultContentTarget(
            tab: "音轨",
            canPlayNext: false,
            episodeFileIDs: [],
            subtitleTrackIDs: [],
            audioTrackIDs: [], // No audio tracks
            currentEpisodeFileID: nil
        )
        XCTAssertEqual(target, .drawerTab("音轨"), "When no audio tracks exist, should not point to silent marker or fake 0")
    }

    func testDrawerDefaultContentTargetSelectsCurrentPlayingEpisode() {
        let target = PlayerInputReducer.defaultContentTarget(
            tab: "选集",
            canPlayNext: true,
            episodeFileIDs: ["f1", "f2", "f3"],
            subtitleTrackIDs: [],
            audioTrackIDs: [],
            currentEpisodeFileID: "f2"
        )
        XCTAssertEqual(target, .episode("f2"), "Drawer open must default focus to current playing episode")
    }

    @MainActor
    func testPlayerPresentationManagerTracksPresentation() {
        PlayerPresentationManager.resetForTesting()
        XCTAssertFalse(PlayerPresentationManager.isPlayerPresented)

        var recordedStates: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: PlayerPresentationManager.notificationName,
            object: nil,
            queue: .main
        ) { notification in
            let isPresented = notification.userInfo?["isPresented"] as? Bool
            MainActor.assumeIsolated {
                if let isPresented {
                    recordedStates.append(isPresented)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        PlayerPresentationManager.playerDidAppear()
        XCTAssertTrue(PlayerPresentationManager.isPlayerPresented)

        PlayerPresentationManager.playerDidDisappear()
        XCTAssertFalse(PlayerPresentationManager.isPlayerPresented)

        XCTAssertEqual(recordedStates, [true, false])
    }

    @MainActor
    func testPlayerPresentationManagerRepeatedAppearBeforeDisappearRestoresPresentation() {
        PlayerPresentationManager.resetForTesting()
        XCTAssertFalse(PlayerPresentationManager.isPlayerPresented)

        var recordedStates: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: PlayerPresentationManager.notificationName,
            object: nil,
            queue: .main
        ) { notification in
            let isPresented = notification.userInfo?["isPresented"] as? Bool
            MainActor.assumeIsolated {
                if let isPresented {
                    recordedStates.append(isPresented)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Simulate SwiftUI triggering onAppear repeatedly before a single onDisappear
        PlayerPresentationManager.playerDidAppear()
        PlayerPresentationManager.playerDidAppear()
        XCTAssertTrue(PlayerPresentationManager.isPlayerPresented)
        XCTAssertEqual(PlayerPresentationManager.activeCount, 1)

        // Single onDisappear must restore presentation state to false and dock visibility
        PlayerPresentationManager.playerDidDisappear()
        XCTAssertFalse(PlayerPresentationManager.isPlayerPresented)
        XCTAssertEqual(PlayerPresentationManager.activeCount, 0)

        // Only genuine state transitions emit notifications
        XCTAssertEqual(recordedStates, [true, false])
    }

    @MainActor
    func testPlayerPresentationManagerPerViewTokenTracking() {
        PlayerPresentationManager.resetForTesting()
        let token = "player-screen-token"

        PlayerPresentationManager.playerDidAppear(token: token)
        PlayerPresentationManager.playerDidAppear(token: token)
        XCTAssertTrue(PlayerPresentationManager.isPlayerPresented)

        PlayerPresentationManager.playerDidDisappear(token: token)
        XCTAssertFalse(PlayerPresentationManager.isPlayerPresented)
    }

    func testDrawerEpisodeRailLayoutMetrics() {
        XCTAssertEqual(DrawerEpisodeRailMetrics.cardsPerViewport, 3)
        XCTAssertGreaterThanOrEqual(DrawerEpisodeRailMetrics.cardWidth, 360)
        XCTAssertEqual(DrawerEpisodeRailMetrics.viewportWidth, 1240)
        XCTAssertEqual(
            DrawerEpisodeRailMetrics.viewportWidth,
            CGFloat(DrawerEpisodeRailMetrics.cardsPerViewport) * DrawerEpisodeRailMetrics.cardWidth +
                CGFloat(DrawerEpisodeRailMetrics.cardsPerViewport - 1) * DrawerEpisodeRailMetrics.cardSpacing +
                (2 * DrawerEpisodeRailMetrics.horizontalPadding)
        )
        // Ensure card interior metrics and rail headroom geometry invariants
        XCTAssertEqual(DrawerEpisodeRailMetrics.cardHeight, DrawerEpisodeRailMetrics.thumbnailHeight + DrawerEpisodeRailMetrics.infoHeight)
        XCTAssertGreaterThanOrEqual(DrawerEpisodeRailMetrics.infoHeight, 80)
        XCTAssertGreaterThanOrEqual(DrawerEpisodeRailMetrics.railHeight, DrawerEpisodeRailMetrics.cardHeight * DrawerEpisodeRailMetrics.focusedScale + 50)
    }

    func testDrawerEpisodeRailNextActionCompositionGeometry() {
        // When next action is available, total width includes extra action and card spacing
        let combinedRailWidth = DrawerEpisodeRailMetrics.totalRailWidth(includingNextAction: true)
        XCTAssertEqual(combinedRailWidth, 1470)
        XCTAssertEqual(combinedRailWidth, DrawerEpisodeRailMetrics.nextActionWidth + DrawerEpisodeRailMetrics.cardSpacing + DrawerEpisodeRailMetrics.viewportWidth)

        // The episode card viewport remains dedicated to 3 full readable cards
        XCTAssertEqual(DrawerEpisodeRailMetrics.cardsPerViewport, 3)

        // Combined drawer width fits on standard tvOS 1920x1080 canvas
        let totalDrawerWidth = DrawerEpisodeRailMetrics.drawerWidth(includingNextAction: true)
        XCTAssertEqual(totalDrawerWidth, 1550)
        XCTAssertLessThanOrEqual(totalDrawerWidth + 80, 1920, "Drawer with next action and margins must fit on 1920 tvOS screen")

        // Without next action (e.g. last episode)
        let railWidthWithoutNext = DrawerEpisodeRailMetrics.totalRailWidth(includingNextAction: false)
        XCTAssertEqual(railWidthWithoutNext, DrawerEpisodeRailMetrics.viewportWidth)
        XCTAssertEqual(DrawerEpisodeRailMetrics.drawerWidth(includingNextAction: false), 1320)
    }

    func testDrawerCardCalculatedFocusGeometryAndClearance() {
        // Geometry check: Validates analytical layout geometry, post-transform scale expansion,
        // and clearance headroom using shared DrawerEpisodeRailMetrics constants.
        // Note: Validates geometry invariants only, not SwiftUI rendering or actual tvOS focus.

        // 1. Verify scale mechanism constants
        XCTAssertEqual(DrawerEpisodeRailMetrics.scale(isFocused: false), 1.0)
        XCTAssertEqual(DrawerEpisodeRailMetrics.scale(isFocused: true), DrawerEpisodeRailMetrics.focusedScale)
        XCTAssertEqual(DrawerEpisodeRailMetrics.focusedScale, 1.05)
        XCTAssertEqual(DrawerEpisodeRailMetrics.focusedShadowRadius, 14.0)
        XCTAssertEqual(DrawerEpisodeRailMetrics.focusedShadowYOffset, 6.0)

        // 2. Computed dimensions under focused scale
        let scaledHeight = DrawerEpisodeRailMetrics.scaledCardHeight
        XCTAssertEqual(scaledHeight, DrawerEpisodeRailMetrics.cardHeight * DrawerEpisodeRailMetrics.focusedScale, accuracy: 0.001)
        XCTAssertEqual(scaledHeight, 231.0, accuracy: 0.001)

        let scaledWidth = DrawerEpisodeRailMetrics.scaledCardWidth
        XCTAssertEqual(scaledWidth, DrawerEpisodeRailMetrics.cardWidth * DrawerEpisodeRailMetrics.focusedScale, accuracy: 0.001)
        XCTAssertEqual(scaledWidth, 388.5, accuracy: 0.001)

        // 3. Calculated scale expansions and directional overflows
        let verticalExpansion = DrawerEpisodeRailMetrics.verticalExpansionPerSide
        XCTAssertEqual(verticalExpansion, (scaledHeight - DrawerEpisodeRailMetrics.cardHeight) / 2.0, accuracy: 0.001)

        let topOverflow = DrawerEpisodeRailMetrics.topOverflow
        XCTAssertEqual(topOverflow, verticalExpansion + DrawerEpisodeRailMetrics.focusedShadowRadius, accuracy: 0.001)

        let bottomOverflow = DrawerEpisodeRailMetrics.bottomOverflow
        XCTAssertEqual(bottomOverflow, verticalExpansion + DrawerEpisodeRailMetrics.focusedShadowRadius + DrawerEpisodeRailMetrics.focusedShadowYOffset, accuracy: 0.001)

        // 4. Safe vertical clearances against rail container and padding
        XCTAssertEqual(DrawerEpisodeRailMetrics.verticalClearance, DrawerEpisodeRailMetrics.railHeight - scaledHeight, accuracy: 0.001)
        XCTAssertEqual(DrawerEpisodeRailMetrics.verticalClearance, 89.0, accuracy: 0.001)
        XCTAssertGreaterThan(DrawerEpisodeRailMetrics.verticalClearance, topOverflow + bottomOverflow, "Total rail vertical clearance must exceed combined top and bottom focus overflow")

        // ScrollView vertical padding (32 pt) exceeds top overflow (19.5 pt) and bottom overflow (25.5 pt)
        XCTAssertGreaterThan(DrawerEpisodeRailMetrics.verticalPadding, topOverflow, "ScrollView vertical padding must exceed top overflow to clear scaled chrome")
        XCTAssertGreaterThan(DrawerEpisodeRailMetrics.verticalPadding, bottomOverflow, "ScrollView vertical padding must exceed bottom overflow")

        // 5. Next action button scale and headroom
        let scaledNextActionHeight = DrawerEpisodeRailMetrics.nextActionHeight * DrawerEpisodeRailMetrics.focusedScale
        XCTAssertEqual(scaledNextActionHeight, 199.5, accuracy: 0.001)
        XCTAssertGreaterThan(DrawerEpisodeRailMetrics.railHeight - scaledNextActionHeight, 100)
    }

    func testDrawerCardFixedCardHeightPartitioning() {
        // Geometry check: Verifies card interior height budget partitioned into banner + info area.
        // Note: This validates analytical layout geometry invariants only, not SwiftUI rendering,
        // font glyph rasterization, or runtime text truncation.
        XCTAssertEqual(DrawerEpisodeRailMetrics.thumbnailHeight + DrawerEpisodeRailMetrics.infoHeight, DrawerEpisodeRailMetrics.cardHeight)
        XCTAssertEqual(DrawerEpisodeRailMetrics.infoHeight, 82.0)
        XCTAssertEqual(DrawerEpisodeRailMetrics.thumbnailHeight, 138.0)

        // In infoArea (82 pt height), padding allowance is 8 pt top + 8 pt bottom = 16 pt
        let availableInfoHeight = DrawerEpisodeRailMetrics.infoHeight - 16.0
        XCTAssertEqual(availableInfoHeight, 66.0)
    }

    func testHorizontalCardSeparationMaintainedUnderFocusScaling() {
        // Geometry check: Validates calculated horizontal safe clearances, separation margin
        // between adjacent cards, and scroll edge padding under focus scale expansion.
        // Note: Arithmetic geometry invariants only, not SwiftUI rendering or actual tvOS focus.

        let singleSideGrowth = DrawerEpisodeRailMetrics.horizontalExpansionPerSide
        XCTAssertEqual(
            singleSideGrowth,
            (DrawerEpisodeRailMetrics.scaledCardWidth - DrawerEpisodeRailMetrics.cardWidth) / 2.0,
            accuracy: 0.001
        )

        let remainingGap = DrawerEpisodeRailMetrics.cardSpacing - singleSideGrowth
        XCTAssertEqual(remainingGap, 20.75, accuracy: 0.001)
        XCTAssertGreaterThan(remainingGap, 20.0, "Remaining horizontal gap between cards must stay positive so focused card never collides with neighbors")

        // Theoretical dual-expansion clearance
        let dualExpansionGap = DrawerEpisodeRailMetrics.cardSpacing - (2.0 * singleSideGrowth)
        XCTAssertGreaterThan(dualExpansionGap, 10.0, "Horizontal gap remains positive even under theoretical dual-side boundary expansion")

        // First/last card horizontal edge safety: ScrollView horizontal padding must exceed
        // horizontal focused overflow (one-side scale expansion + focused shadow radius).
        let expectedHorizontalOverflow = singleSideGrowth + DrawerEpisodeRailMetrics.focusedShadowRadius
        XCTAssertEqual(DrawerEpisodeRailMetrics.horizontalOverflow, expectedHorizontalOverflow, accuracy: 0.001)
        XCTAssertEqual(DrawerEpisodeRailMetrics.horizontalOverflow, 23.25, accuracy: 0.001)
        XCTAssertGreaterThan(
            DrawerEpisodeRailMetrics.horizontalPadding,
            DrawerEpisodeRailMetrics.horizontalOverflow,
            "ScrollView horizontal padding must exceed horizontal focused overflow so first and last cards maintain edge clearance"
        )
    }
}
