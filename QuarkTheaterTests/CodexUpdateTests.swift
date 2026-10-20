import XCTest
@preconcurrency import KSPlayer
@testable import QuarkTheater

final class SpyPlayerLayer: KSPlayerLayer, @unchecked Sendable {
    nonisolated(unsafe) var stateChangedCallbackAtPlayTime: ((KSPlayerLayer, KSPlayerState) -> Void)?
    nonisolated(unsafe) var playCallbackAtPlayTime: ((TimeInterval, TimeInterval) -> Void)?
    nonisolated(unsafe) var playCallCount = 0
    nonisolated(unsafe) weak var observedCoordinator: KSVideoPlayer.Coordinator?

    override func play() {
        playCallCount += 1
        if playCallCount == 1 {
            MainActor.assumeIsolated {
                stateChangedCallbackAtPlayTime = observedCoordinator?.onStateChanged
                playCallbackAtPlayTime = observedCoordinator?.onPlay
            }
        }
        super.play()
    }
}

@MainActor
final class CodexUpdateTests: XCTestCase {

    // MARK: - 1. MatchDecisionPolicy Tests
    func testMatchDecisionPolicyThresholds() {
        let dummy = TMDBSearchResult(
            id: 1,
            title: "Test",
            name: nil,
            originalTitle: nil,
            originalName: nil,
            releaseDate: "2024-01-01",
            firstAirDate: nil,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            voteAverage: 8.0,
            genreIDs: nil
        )

        // Confidence >= 0.95 -> autoConfirm
        let highConf = MatchDecisionPolicy.evaluate([ScoredTMDBResult(result: dummy, confidence: 0.98)])
        XCTAssertTrue(highConf.isAutoConfirmed)

        // Confidence 0.85 -> needsUserConfirmation
        let midConf = MatchDecisionPolicy.evaluate([ScoredTMDBResult(result: dummy, confidence: 0.85)])
        XCTAssertFalse(midConf.isAutoConfirmed)
        if case .needsUserConfirmation(let candidates, _) = midConf {
            XCTAssertEqual(candidates.first?.confidence, 0.85)
        } else {
            XCTFail("Expected needsUserConfirmation for 0.85 confidence")
        }

        // Confidence < 0.82 -> unmatched
        let lowConf = MatchDecisionPolicy.evaluate([ScoredTMDBResult(result: dummy, confidence: 0.70)])
        XCTAssertFalse(lowConf.isAutoConfirmed)
        if case .unmatched = lowConf {
            // Success
        } else {
            XCTFail("Expected unmatched for 0.70 confidence")
        }
    }

    // MARK: - 2. Chinese Season Numerals & High Castle Season 4
    func testHighCastleSeason4BothFormats() {
        let englishFolder = FilenameParser.parse(
            "04.mp4",
            pathComponents: ["来自：分享", "G 高堡奇人S01~S04", "Season 04"],
            boundRootName: nil
        )
        XCTAssertEqual(englishFolder.title, "高堡奇人")
        XCTAssertEqual(englishFolder.seasonNumber, 4)
        XCTAssertEqual(englishFolder.episodeNumber, 4)

        let chineseFolder = FilenameParser.parse(
            "10.mp4",
            pathComponents: ["高堡奇人", "第四季"],
            boundRootName: nil
        )
        XCTAssertEqual(chineseFolder.title, "高堡奇人")
        XCTAssertEqual(chineseFolder.seasonNumber, 4)
        XCTAssertEqual(chineseFolder.episodeNumber, 10)
    }

    // MARK: - 3. Censorship & Alias Resolution (Project Hail Mary)
    func testProjectHailMaryAliasAndCensorship() {
        let cleaned = FilenameParser.folderTitle("挽救#J划 Project Hail Mary (2026)(1)")
        XCTAssertEqual(cleaned, "挽救计划 Project Hail Mary")

        let variants = MediaAliasResolver.variants(for: "挽救#J划")
        XCTAssertTrue(variants.contains("挽救计划"))
    }

    // MARK: - 4. PlayerInputReducer Tests
    func testPlayerInputReducerSeekWhenDrawerClosed() {
        let state = PlayerInputState(
            isDrawerOpen: false,
            selectedDrawerTab: "选集列表",
            focusedTarget: nil,
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600
        )

        let leftAction = PlayerInputReducer.reduce(state: state, direction: .left, seekInterval: 10)
        XCTAssertEqual(leftAction, .seek(direction: .backward, interval: 10))

        let rightAction = PlayerInputReducer.reduce(state: state, direction: .right, seekInterval: 15)
        XCTAssertEqual(rightAction, .seek(direction: .forward, interval: 15))

        let downAction = PlayerInputReducer.reduce(state: state, direction: .down, seekInterval: 10)
        XCTAssertEqual(downAction, .openDrawer)
    }

    func testPlayerInputReducerDrawerOpenSuppressesSeek() {
        let state = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .drawerTab("选集"),
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600,
            episodeFileIDs: ["ep1", "ep2", "ep3"],
            subtitleTrackIDs: ["off", "0"],
            audioTrackIDs: ["0", "1"]
        )

        // Left from leftmost tab stays at none (doesn't seek)
        let leftAction = PlayerInputReducer.reduce(state: state, direction: .left, seekInterval: 10)
        XCTAssertEqual(leftAction, .none)

        // Horizontal movement is owned by the tvOS focus engine.
        let rightAction = PlayerInputReducer.reduce(state: state, direction: .right, seekInterval: 15)
        XCTAssertEqual(rightAction, .none)

        // Up arrow does NOT close drawer (Requirement: only back/menu key closes drawer)
        let upAction = PlayerInputReducer.reduce(state: state, direction: .up, seekInterval: 10)
        XCTAssertEqual(upAction, .none)

        // Down arrow enters content items
        let downAction = PlayerInputReducer.reduce(state: state, direction: .down, seekInterval: 10)
        XCTAssertEqual(downAction, .focusTarget(.nextEpisode))

        // Navigate within content area
        let contentState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .nextEpisode,
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600,
            episodeFileIDs: ["ep1", "ep2"],
            subtitleTrackIDs: ["off"],
            audioTrackIDs: ["0"]
        )
        let nextEpAction = PlayerInputReducer.reduce(state: contentState, direction: .right, seekInterval: 10)
        XCTAssertEqual(nextEpAction, .none)

        // Up from content returns to tab
        let upFromContent = PlayerInputReducer.reduce(state: contentState, direction: .up, seekInterval: 10)
        XCTAssertEqual(upFromContent, .focusTarget(.drawerTab("选集")))
    }

    func testPlayerInputReducerLeavesDrawerHorizontalMovementToSingleFocusOwner() {
        let state = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .episode("ep2"),
            canPlayNext: false,
            currentPlaybackTime: 100,
            duration: 3600,
            episodeFileIDs: ["ep1", "ep2", "ep3"]
        )

        XCTAssertEqual(
            PlayerInputReducer.reduce(state: state, direction: .left, seekInterval: 10),
            .none
        )
        XCTAssertEqual(
            PlayerInputReducer.reduce(state: state, direction: .right, seekInterval: 10),
            .none
        )
    }

    func testDrawerBackClosesDrawerFromEveryFocusLevel() {
        // Back is a drawer dismissal action regardless of the focused control.
        let episodeContentState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .episode("ep5"),
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600,
            episodeFileIDs: ["ep1", "ep2", "ep3", "ep4", "ep5"]
        )
        let backFromEpisode = PlayerInputReducer.handleBack(state: episodeContentState)
        XCTAssertEqual(backFromEpisode, .closeDrawer)

        let subtitleContentState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "字幕",
            focusedTarget: .subtitle("1"),
            canPlayNext: false,
            currentPlaybackTime: 100,
            duration: 3600
        )
        let backFromSubtitle = PlayerInputReducer.handleBack(state: subtitleContentState)
        XCTAssertEqual(backFromSubtitle, .closeDrawer)

        let audioContentState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "音轨",
            focusedTarget: .audio("2"),
            canPlayNext: false,
            currentPlaybackTime: 100,
            duration: 3600
        )
        let backFromAudio = PlayerInputReducer.handleBack(state: audioContentState)
        XCTAssertEqual(backFromAudio, .closeDrawer)

        // Tab level also closes the drawer.
        let tabState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .drawerTab("选集"),
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600
        )
        let backFromTab = PlayerInputReducer.handleBack(state: tabState)
        XCTAssertEqual(backFromTab, .closeDrawer)

        // Drawer closed: Back is not handled by drawer reducer (.none), player can exit.
        let closedState = PlayerInputState(
            isDrawerOpen: false,
            selectedDrawerTab: "选集",
            focusedTarget: .drawerTrigger,
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600
        )
        let backWhenClosed = PlayerInputReducer.handleBack(state: closedState)
        XCTAssertEqual(backWhenClosed, .none)

        // Any unexpected focus in drawer still closes the drawer instead of exiting player.
        let nilFocusState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: nil,
            canPlayNext: true,
            currentPlaybackTime: 100,
            duration: 3600
        )
        let backFromNil = PlayerInputReducer.handleBack(state: nilFocusState)
        XCTAssertEqual(backFromNil, .closeDrawer)
    }

    func testDrawerDefaultEpisodeFocusPrefersCurrentPlayingFile() {
        XCTAssertEqual(
            PlayerInputReducer.defaultContentTarget(
                tab: "选集",
                canPlayNext: true,
                episodeFileIDs: ["ep1", "ep5"],
                currentEpisodeFileID: "ep5"
            ),
            .episode("ep5")
        )
        XCTAssertEqual(
            PlayerInputReducer.defaultContentTarget(
                tab: "选集",
                canPlayNext: true,
                episodeFileIDs: ["ep1", "ep5"],
                currentEpisodeFileID: nil
            ),
            .nextEpisode
        )
    }

    func testDrawerUpHierarchyReturnsFromContentToTabAndTabDoesNotClose() {
        // Up from episode content returns to tab
        let contentState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .episode("ep5"),
            canPlayNext: false,
            currentPlaybackTime: 100,
            duration: 3600,
            episodeFileIDs: ["ep5"]
        )
        let upFromContent = PlayerInputReducer.reduce(state: contentState, direction: .up, seekInterval: 10)
        XCTAssertEqual(upFromContent, .focusTarget(.drawerTab("选集")))

        // Up from tab stays on tab level, does not close drawer
        let tabState = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .drawerTab("选集"),
            canPlayNext: false,
            currentPlaybackTime: 100,
            duration: 3600
        )
        let upFromTab = PlayerInputReducer.reduce(state: tabState, direction: .up, seekInterval: 10)
        XCTAssertEqual(upFromTab, .none)
    }

    func testEpisodeMetadataProjectionPrefersConfirmedValuesAndLeavesUnknownUnresolved() {
        let parsed = ParsedMediaName(title: "Show", mediaType: .series,
                                     seasonNumber: 1, episodeNumber: 1, inferredFromParent: false)
        let confirmed = MediaItem(id: "m", fileId: "f", mediaType: .series,
                                  title: "Show", seasonNumber: 2, episodeNumber: 7)
        let projected = EpisodeMetadataProjection.project(metadata: confirmed, parsed: parsed)
        XCTAssertEqual(projected.seasonNumber, 2)
        XCTAssertEqual(projected.episodeNumber, 7)

        let unresolved = MediaItem(id: "u", fileId: "u", mediaType: .series,
                                   title: "Show", seasonNumber: 2, episodeNumber: nil)
        let unresolvedProjection = EpisodeMetadataProjection.project(
            metadata: unresolved,
            parsed: ParsedMediaName(title: "Show", mediaType: .series,
                                    seasonNumber: 2, episodeNumber: nil, inferredFromParent: true)
        )
        XCTAssertNil(unresolvedProjection.episodeNumber)
        XCTAssertEqual(EpisodeMetadataProjection.displayEpisodeNumber(unresolvedProjection), nil)
    }

    func testConfirmedUnknownEpisodeDoesNotFallBackToFilenameEpisode() {
        let confirmed = MediaItem(id: "u", fileId: "u", mediaType: .series,
                                  title: "Show", seasonNumber: 2, episodeNumber: nil)
        let parsed = ParsedMediaName(title: "Show", mediaType: .series,
                                     seasonNumber: 2, episodeNumber: 1,
                                     inferredFromParent: false)

        let projected = EpisodeMetadataProjection.project(metadata: confirmed, parsed: parsed)

        XCTAssertNil(projected.episodeNumber)
    }

    func testMovieQuickPlayUsesTheSelectedMediaItemFileAsSingleFileQueue() {
        let movie = MediaItem(id: "movie", fileId: "movie-preferred", mediaType: .movie,
                              title: "Movie")
        let preferred = CloudFile(fileId: "movie-preferred", parentId: "movies", name: "Movie.mp4",
                                  size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let alternate = CloudFile(fileId: "movie-alternate", parentId: "movies", name: "Movie HDR.mp4",
                                  size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)

        let projection = MediaLibraryPlaybackProjection.quickPlay(item: movie, episodes: [
            (movie, alternate, ParsedMediaName(title: "Movie", mediaType: .movie)),
            (movie, preferred, ParsedMediaName(title: "Movie", mediaType: .movie))
        ])

        XCTAssertEqual(projection?.selected.fileId, "movie-preferred")
        XCTAssertEqual(projection?.queue.map(\.fileId), ["movie-preferred"])
    }

    func testSeriesQuickPlayStillRequiresKnownEpisodeNumbers() {
        let show = MediaItem(id: "show", fileId: "show-unknown", mediaType: .series,
                             title: "Show")
        let unknown = CloudFile(fileId: "show-unknown", parentId: "show", name: "KAPI.mp4",
                                size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)

        XCTAssertNil(MediaLibraryPlaybackProjection.quickPlay(item: show, episodes: [
            (show, unknown, ParsedMediaName(title: "Show", mediaType: .series,
                                            episodeNumber: nil, unresolvedReason: .missingSeriesContext))
        ]))
    }

    func testSubtitleResourceURLUsesTheVerifiedPlaybackURL() throws {
        let resourceURL = try XCTUnwrap(URL(string: "https://cdn.example.test/video.m3u8"))
        XCTAssertEqual(PlaybackCoordinator.subtitleResourceURL(for: resourceURL), resourceURL)
    }

    @MainActor
    func testPlaybackResourceMustMatchPendingSelectionAndGeneration() {
        XCTAssertTrue(PlaybackCoordinator.shouldAcceptPlaybackResource(
            requestGeneration: 3, currentGeneration: 3,
            requestedFileID: "episode-a", currentFileID: "episode-a",
            resourceFileID: "episode-a", isCancelled: false
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldAcceptPlaybackResource(
            requestGeneration: 3, currentGeneration: 4,
            requestedFileID: "episode-a", currentFileID: "episode-b",
            resourceFileID: "episode-a", isCancelled: false
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldAcceptPlaybackResource(
            requestGeneration: 3, currentGeneration: 3,
            requestedFileID: "episode-a", currentFileID: "episode-a",
            resourceFileID: "episode-b", isCancelled: false
        ))
    }

    @MainActor
    func testEpisodeReplacementPausesOnlyWhenSwitchingFromAnActiveFile() {
        XCTAssertEqual(
            PlaybackCoordinator.replacementAction(hasActivePlayer: true, isNewFile: true),
            .pauseAndPlay
        )
        XCTAssertEqual(
            PlaybackCoordinator.replacementAction(hasActivePlayer: false, isNewFile: true),
            .startNormally
        )
        XCTAssertEqual(
            PlaybackCoordinator.replacementAction(hasActivePlayer: true, isNewFile: false),
            .startNormally
        )
        XCTAssertTrue(PlaybackCoordinator.shouldPausePlayerBeforeReplacement(
            hasActivePlayer: true, isNewFile: true
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldPausePlayerBeforeReplacement(
            hasActivePlayer: false, isNewFile: true
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldPausePlayerBeforeReplacement(
            hasActivePlayer: true, isNewFile: false
        ))
    }

    func testSameCurrentFileWithoutPendingReplacementDoesNotPause() {
        XCTAssertFalse(PlaybackCoordinator.isNewPlaybackFile(
            targetFileID: "episode-a", currentFileID: "episode-a", pendingFileID: nil
        ))
        XCTAssertFalse(PlaybackCoordinator.shouldPausePlayerBeforeReplacement(
            hasActivePlayer: true,
            isNewFile: PlaybackCoordinator.isNewPlaybackFile(
                targetFileID: "episode-a", currentFileID: "episode-a", pendingFileID: nil
            )
        ))
    }

    func testEpisodeSelectionSwitchesPendingAndCommittedPlaybackFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))

        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep5 = CloudFile(fileId: "ep5", parentId: "show", name: "Show.S01E05.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)

        let ep1Resource = PlaybackResource(
            fileID: "ep1",
            url: URL(string: "https://pan.quark.cn/stream/ep1.mp4")!,
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )
        let ep5Resource = PlaybackResource(
            fileID: "ep5",
            url: URL(string: "https://pan.quark.cn/stream/ep5.mp4")!,
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )

        let stubClient = EpisodeSwitchStubClient()
        let coordinator = PlaybackCoordinator(
            client: stubClient,
            accountID: "account-1",
            file: ep1,
            queue: [ep1, ep5],
            history: history,
            diagnostics: diagnostics
        )

        // 1. Initial play started for ep1 (stub holds ep1 continuation to simulate slow resolution)
        let ep1StartTask = Task { await coordinator.start() }
        for _ in 0..<20 {
            if stubClient.requestedFileIDs.contains("ep1") { break }
            await Task.yield()
        }
        XCTAssertEqual(stubClient.requestedFileIDs, ["ep1"])
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertNil(coordinator.ksPlayerURL)

        // 2. User selects episode 5 in drawer (ep5 network in flight)
        let switchTask = coordinator.playFile(ep5, selectionOrdinal: 1, episodeNumber: 5)
        for _ in 0..<20 {
            if stubClient.requestedFileIDs.contains("ep5") { break }
            await Task.yield()
        }

        // 3. While ep5 is resolving: pending file is ep5, current file is still ep1
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep5")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertNil(coordinator.ksPlayerURL)
        XCTAssertEqual(stubClient.requestedFileIDs, ["ep1", "ep5"])
        await diagnostics.waitForPendingOperations()
        XCTAssertTrue(diagnostics.records.contains { $0.event == .episodeSelectionRequested })
        XCTAssertFalse(diagnostics.records.contains { $0.event == .started })

        // 4. Outdated ep1 response resolves after ep5 was already requested
        stubClient.resumeContinuation(for: "ep1", with: .success(ep1Resource))
        _ = await ep1StartTask.result

        // Stale ep1 must NOT overwrite pending switch or current identity or KS URL
        XCTAssertNil(coordinator.ksPlayerURL)
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep5")

        // 5. Ep5 network finishes and playback commits
        stubClient.resumeContinuation(for: "ep5", with: .success(ep5Resource))
        _ = await switchTask.value

        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep5")
        XCTAssertEqual(coordinator.ksPlayerURL, ep5Resource.url)
        XCTAssertNil(coordinator.pendingFile)
        XCTAssertFalse(coordinator.isCurrentPlaybackStarted)
        XCTAssertTrue(coordinator.isPlaybackTransitionActive)
        await diagnostics.waitForPendingOperations()
        let selection = try XCTUnwrap(diagnostics.records.first { $0.event == .episodeSelectionRequested })
        XCTAssertEqual(selection.metadata["episodeOrdinal"], .int(1))
        XCTAssertEqual(selection.metadata["episodeNumber"], .int(5))
        XCTAssertFalse(diagnostics.records.contains { $0.event == .started })

        coordinator.ksCoordinator.onPlay?(0, 100)
        await diagnostics.waitForPendingOperations()
        XCTAssertTrue(coordinator.isCurrentPlaybackStarted)
        XCTAssertFalse(coordinator.isPlaybackTransitionActive)
        let started = try XCTUnwrap(diagnostics.records.first { $0.event == .started })
        XCTAssertEqual(started.correlationID, selection.correlationID)
        XCTAssertEqual(started.metadata["episodeOrdinal"], .int(1))
    }

    func testEpisodeReplacementRegistersCallbacksBeforePlayerLayerSetAndPlay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-callbacks-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))

        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep5 = CloudFile(fileId: "ep5", parentId: "show", name: "Show.S01E05.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep5Resource = PlaybackResource(
            fileID: "ep5",
            url: URL(string: "https://pan.quark.cn/stream/ep5.mp4")!,
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )

        let stubClient = EpisodeSwitchStubClient()
        stubClient.resources["ep5"] = ep5Resource
        let coordinator = PlaybackCoordinator(
            client: stubClient,
            accountID: "account-1",
            file: ep1,
            queue: [ep1, ep5],
            history: history,
            diagnostics: diagnostics
        )

        // Mount a spy layer to simulate an already-active playback session (e.g. from ep1)
        let dummyURL = URL(string: "https://pan.quark.cn/stream/ep1.mp4")!
        let spyLayer = SpyPlayerLayer(url: dummyURL, options: KSOptions())
        spyLayer.observedCoordinator = coordinator.ksCoordinator
        coordinator.ksCoordinator.playerLayer = spyLayer

        // Switch to Episode 5
        let switchTask = coordinator.playFile(ep5, selectionOrdinal: 1, episodeNumber: 5)
        _ = await switchTask.value

        // Under root cause: callbacks were cleared and only re-registered AFTER set/play,
        // so stateChangedCallbackAtPlayTime was nil on the first play() invocation!
        XCTAssertNotNil(spyLayer.stateChangedCallbackAtPlayTime, "Callbacks MUST be registered before playerLayer playback is initiated so initial preparation/buffering states are captured.")
        XCTAssertNotNil(spyLayer.playCallbackAtPlayTime, "onPlay callback MUST be registered before playerLayer playback is initiated so early playback ticks are not dropped.")

        // Verify readiness diagnostics distinguishing observed audio/video facts
        coordinator.ksCoordinator.onStateChanged?(spyLayer, .readyToPlay)
        coordinator.ksCoordinator.onBufferChanged?(0, 0.25)
        await diagnostics.waitForPendingOperations()

        let readiness = try XCTUnwrap(diagnostics.records.first { $0.event == .playerReadiness })
        XCTAssertEqual(readiness.metadata["switchGeneration"], .int(1))
        XCTAssertNotNil(readiness.metadata["audioTrackPresent"])
        XCTAssertNotNil(readiness.metadata["videoTrackPresent"])
        XCTAssertNotNil(readiness.metadata["videoNaturalSizeAvailable"])

        let firstBuffer = try XCTUnwrap(diagnostics.records.first { $0.event == .firstBufferReady })
        XCTAssertEqual(firstBuffer.metadata["switchGeneration"], .int(1))
        XCTAssertEqual(firstBuffer.metadata["firstBufferReady"], .bool(true))
    }

    func testMatchingPlaybackFailureClearsPendingWithoutChangingCommittedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-failure-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep5 = CloudFile(fileId: "ep5", parentId: "show", name: "Show.S01E05.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let stubClient = EpisodeSwitchStubClient()
        let coordinator = PlaybackCoordinator(client: stubClient, accountID: "account-1", file: ep1, queue: [ep1, ep5], history: history, diagnostics: diagnostics)

        let task = coordinator.playFile(ep5, selectionOrdinal: 1, episodeNumber: 5)
        for _ in 0..<20 {
            if stubClient.requestedFileIDs.contains("ep5") { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep5")
        stubClient.resumeContinuation(for: "ep5", with: .failure(QuarkError.mockOnly))
        _ = await task.value

        XCTAssertNil(coordinator.pendingFile)
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertFalse(coordinator.isCurrentPlaybackStarted)
        XCTAssertFalse(coordinator.isPlaybackTransitionActive)
    }

    func testRetryFailureClearsTransitionAfterSecondTimeout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-retry-(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep5 = CloudFile(fileId: "ep5", parentId: "show", name: "Show.S01E05.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let stubClient = EpisodeSwitchStubClient()
        stubClient.scriptedResults["ep5"] = [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut))
        ]
        let coordinator = PlaybackCoordinator(client: stubClient, accountID: "account-1", file: ep1, queue: [ep1, ep5], history: history, diagnostics: diagnostics)

        let task = coordinator.playFile(ep5, selectionOrdinal: 1, episodeNumber: 5)
        _ = await task.value
        XCTAssertTrue(coordinator.isPlaybackTransitionActive)

        for _ in 0..<80 {
            if !coordinator.isPlaybackTransitionActive { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(stubClient.requestedFileIDs, ["ep5", "ep5"])
        XCTAssertNil(coordinator.pendingFile)
        XCTAssertFalse(coordinator.isPlaybackTransitionActive)
        XCTAssertFalse(coordinator.isCurrentPlaybackStarted)
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertNotNil(coordinator.message)
    }

    func testSyncPolicyLeavesUnparsedSeriesInManualConfirmation() {
        let unresolved = ScannedMediaCandidate(
            file: CloudFile(fileId: "unknown", parentId: "show", name: "KAPI.mp4", size: 0,
                            fileExtension: "mp4", modifiedAt: nil, isDirectory: false),
            parsedName: ParsedMediaName(title: "Show", mediaType: .series, seasonNumber: 1,
                                        episodeNumber: nil, unresolvedReason: .missingSeriesContext)
        )
        let movie = ScannedMediaCandidate(
            file: CloudFile(fileId: "movie", parentId: "movies", name: "Movie.mp4", size: 0,
                            fileExtension: "mp4", modifiedAt: nil, isDirectory: false),
            parsedName: ParsedMediaName(title: "Movie", mediaType: .movie)
        )

        XCTAssertFalse(MediaLibrarySyncPolicy.shouldAutoRematch(candidate: unresolved, isConfirmed: false))
        XCTAssertTrue(MediaLibrarySyncPolicy.needsManualConfirmation(candidate: unresolved, isConfirmed: false))
        XCTAssertTrue(MediaLibrarySyncPolicy.shouldAutoRematch(candidate: movie, isConfirmed: false))
        XCTAssertFalse(MediaLibrarySyncPolicy.needsManualConfirmation(candidate: movie, isConfirmed: false))
        XCTAssertFalse(MediaLibrarySyncPolicy.shouldAutoRematch(candidate: unresolved, isConfirmed: true))
        XCTAssertFalse(MediaLibrarySyncPolicy.needsManualConfirmation(candidate: unresolved, isConfirmed: true))
    }

    func testPlaybackQueueUsesNaturalEpisodeOrder() {
        let files = [
            CloudFile(fileId: "10", parentId: "s1", name: "10.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false),
            CloudFile(fileId: "2", parentId: "s1", name: "2.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false),
            CloudFile(fileId: "1", parentId: "s1", name: "1.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        ]
        let metadata = Dictionary(uniqueKeysWithValues: files.map {
            ($0.fileId, ParsedMediaName(title: "Show", mediaType: .series,
                                        seasonNumber: 1, episodeNumber: Int($0.fileId)))
        })
        XCTAssertEqual(PlaybackQueueProjection.sort(files, metadata: metadata).map(\.fileId), ["1", "2", "10"])
    }

    func testPlaybackQueueKeepsConfirmedMetadataAndIsolatesUnresolvedFiles() {
        let confirmed = CloudFile(fileId: "confirmed", parentId: "s1", name: "old-name.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let unresolved = CloudFile(fileId: "unknown", parentId: "s1", name: "KAPI_26-07-11_064912.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let metadata = [
            confirmed.fileId: ParsedMediaName(title: "Show", mediaType: .series, seasonNumber: 1, episodeNumber: 5),
            unresolved.fileId: ParsedMediaName(title: "Show", mediaType: .series, seasonNumber: 1, episodeNumber: nil, unresolvedReason: .missingSeriesContext)
        ]
        XCTAssertEqual(PlaybackQueueProjection.automaticFiles([unresolved, confirmed], metadata: metadata).map(\.fileId), ["confirmed"])
        XCTAssertEqual(metadata[confirmed.fileId]?.episodeNumber, 5)
        XCTAssertNil(metadata[unresolved.fileId]?.episodeNumber)
    }

    func testDirectQueueUsesConfirmedEpisodeOverStaleFilenameParse() {
        let file = CloudFile(fileId: "confirmed", parentId: "show", name: "01.mp4", size: 0,
                             fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let projected = ParsedMediaName(title: "Show", mediaType: .series,
                                        seasonNumber: 1, episodeNumber: 5)
        XCTAssertEqual(
            PlaybackQueueProjection.directQueue(files: [file], selected: file,
                                                metadata: [file.fileId: projected]).map(\.fileId),
            ["confirmed"]
        )
    }

    func testDirectQueueRestrictsConfirmedSeriesAndSeason() {
        func file(_ id: String) -> CloudFile {
            CloudFile(fileId: id, parentId: "mixed", name: "\(id).mp4", size: 0,
                      fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        }
        let selected = file("s1e1")
        let sameSeason = file("s1e2")
        let otherSeason = file("s2e1")
        let otherShow = file("other-s1e1")
        let files = [selected, sameSeason, otherSeason, otherShow]
        let metadata = Dictionary(uniqueKeysWithValues: files.map {
            ($0.fileId, ParsedMediaName(title: "Parsed", mediaType: .series,
                                        seasonNumber: $0.fileId == "s2e1" ? 2 : 1,
                                        episodeNumber: 1))
        })
        let confirmed = [
            "s1e1": MediaItem(id: "a", fileId: "s1e1", mediaType: .series, title: "Show A", tmdbId: 100, seasonNumber: 1, episodeNumber: 1),
            "s1e2": MediaItem(id: "b", fileId: "s1e2", mediaType: .series, title: "Show A", tmdbId: 100, seasonNumber: 1, episodeNumber: 2),
            "s2e1": MediaItem(id: "c", fileId: "s2e1", mediaType: .series, title: "Show A", tmdbId: 100, seasonNumber: 2, episodeNumber: 1),
            "other-s1e1": MediaItem(id: "d", fileId: "other-s1e1", mediaType: .series, title: "Show B", tmdbId: 200, seasonNumber: 1, episodeNumber: 1)
        ]
        XCTAssertEqual(
            PlaybackQueueProjection.directQueue(files: files, selected: selected, metadata: metadata, confirmed: confirmed).map(\.fileId),
            ["s1e1", "s1e2"]
        )
    }

    func testDirectQueueDoesNotMixParsedSeriesWhenCatalogIsUnavailable() {
        let selected = CloudFile(fileId: "show-a-1", parentId: "mixed", name: "A-01.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let sameShow = CloudFile(fileId: "show-a-2", parentId: "mixed", name: "A-02.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let otherShow = CloudFile(fileId: "show-b-1", parentId: "mixed", name: "B-01.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let metadata = [
            "show-a-1": ParsedMediaName(title: "Show A", mediaType: .series, episodeNumber: 1),
            "show-a-2": ParsedMediaName(title: "Show A", mediaType: .series, episodeNumber: 2),
            "show-b-1": ParsedMediaName(title: "Show B", mediaType: .series, episodeNumber: 1)
        ]
        XCTAssertEqual(
            PlaybackQueueProjection.directQueue(files: [selected, sameShow, otherShow], selected: selected, metadata: metadata).map(\.fileId),
            ["show-a-1", "show-a-2"]
        )
    }

    func testDirectQueueDoesNotMixDifferentParsedSeriesWithSameSeason() {
        let selected = CloudFile(fileId: "show-a-s1e1", parentId: "mixed", name: "Show A S01E01.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let sameShow = CloudFile(fileId: "show-a-s1e2", parentId: "mixed", name: "Show A S01E02.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let otherShow = CloudFile(fileId: "show-b-s1e1", parentId: "mixed", name: "Show B S01E01.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let metadata = [
            selected.fileId: ParsedMediaName(title: "Show A", mediaType: .series, seasonNumber: 1, episodeNumber: 1),
            sameShow.fileId: ParsedMediaName(title: "Show A", mediaType: .series, seasonNumber: 1, episodeNumber: 2),
            otherShow.fileId: ParsedMediaName(title: "Show B", mediaType: .series, seasonNumber: 1, episodeNumber: 1)
        ]
        XCTAssertEqual(
            PlaybackQueueProjection.directQueue(files: [selected, sameShow, otherShow], selected: selected, metadata: metadata).map(\.fileId),
            ["show-a-s1e1", "show-a-s1e2"]
        )
    }

    func testDirectQueueFallsBackToSelectedWhenSeasonHasNoSeriesTitleContext() {
        let selected = CloudFile(fileId: "selected", parentId: "mixed", name: "01.mp4", size: 0,
                                 fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let other = CloudFile(fileId: "other", parentId: "mixed", name: "Other 01.mp4", size: 0,
                              fileExtension: "mp4", modifiedAt: nil, isDirectory: false)

        let emptyTitle = ParsedMediaName(title: "", mediaType: .series, seasonNumber: 1, episodeNumber: 1)
        let metadata = [
            selected.fileId: emptyTitle,
            other.fileId: ParsedMediaName(title: "Other Show", mediaType: .series,
                                          seasonNumber: 1, episodeNumber: 2)
        ]

        XCTAssertEqual(
            PlaybackQueueProjection.directQueue(files: [selected, other], selected: selected,
                                                metadata: metadata).map(\.fileId),
            ["selected"]
        )
    }

    func testDirectQueueFallsBackToSelectedForUnknownMediaTypeEvenWithSeason() {
        let selected = CloudFile(fileId: "selected-unknown", parentId: "mixed", name: "01.mp4", size: 0,
                                 fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let other = CloudFile(fileId: "other-series", parentId: "mixed", name: "Other 01.mp4", size: 0,
                              fileExtension: "mp4", modifiedAt: nil, isDirectory: false)

        let metadata = [
            selected.fileId: ParsedMediaName(title: "", mediaType: .unknown, seasonNumber: 1, episodeNumber: 1),
            other.fileId: ParsedMediaName(title: "Other Show", mediaType: .series,
                                          seasonNumber: 1, episodeNumber: 2)
        ]

        XCTAssertEqual(
            PlaybackQueueProjection.directQueue(files: [selected, other], selected: selected,
                                                metadata: metadata).map(\.fileId),
            ["selected-unknown"]
        )
    }

    @MainActor
    func testDetailPlaybackQueueIsolatesUnresolvedManualSelection() {
        let known = MediaItem(id: "known", fileId: "known", mediaType: .series, title: "Show", seasonNumber: 1, episodeNumber: 2)
        let unknown = MediaItem(id: "unknown", fileId: "unknown", mediaType: .series, title: "Show", seasonNumber: 1, episodeNumber: nil)
        let knownFile = CloudFile(fileId: "known", parentId: "s1", name: "02.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let unknownFile = CloudFile(fileId: "unknown", parentId: "s1", name: "KAPI.mp4", size: 0, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let episodes: [(MediaItem, CloudFile, ParsedMediaName)] = [
            (known, knownFile, ParsedMediaName(title: "Show", mediaType: .series, seasonNumber: 1, episodeNumber: 2)),
            (unknown, unknownFile, ParsedMediaName(title: "Show", mediaType: .series, seasonNumber: 1, episodeNumber: nil, unresolvedReason: .missingSeriesContext))
        ]
        XCTAssertEqual(MediaItemDetailScreen.playbackQueue(for: unknownFile, episodes: episodes).map(\.fileId), ["unknown"])
        XCTAssertEqual(MediaItemDetailScreen.playbackQueue(for: knownFile, episodes: episodes).map(\.fileId), ["known"])
    }

    func testReducerProjectsNativeDrawerTabFocusToSelectedTab() {
        XCTAssertEqual(
            PlayerInputReducer.selectedTabName(for: .drawerTab("字幕")),
            "字幕"
        )
        XCTAssertNil(PlayerInputReducer.selectedTabName(for: .episode("episode-a")))
    }

    // MARK: - 5. PlaybackPreferences
    func testPlaybackPreferencesDefaults() {
        XCTAssertTrue(PlaybackPreferences.isKSPlayerPreferred)
        XCTAssertEqual(PlaybackPreferences.defaultSeekInterval, 10)
        XCTAssertEqual(PlaybackPreferences.allowedSeekIntervals, [10, 15])
    }

    // MARK: - 6. StoragePaths & Migration
    func testStoragePathsApplicationSupportDirectory() {
        let appSupport = StoragePaths.appSupportDirectory
        XCTAssertNotNil(appSupport)
        XCTAssertTrue(appSupport?.path.contains("Application Support/QuarkTheater") ?? false)
        XCTAssertEqual(StoragePaths.mediaCatalogDatabaseURL()?.lastPathComponent, "media-catalog.sqlite")
        XCTAssertEqual(StoragePaths.watchHistoryDatabaseURL()?.lastPathComponent, "watch-history.sqlite")
    }
}

@MainActor
private final class EpisodeSwitchStubClient: QuarkClient {
    var requestedFileIDs: [String] = []
    var resources: [String: PlaybackResource] = [:]
    var scriptedResults: [String: [Result<PlaybackResource, Error>]] = [:]
    var pendingContinuations: [String: CheckedContinuation<PlaybackResource, Error>] = [:]

    func restoreSession() async throws -> Account? { nil }
    func beginQRCodeLogin() async throws -> QRLoginChallenge { throw QuarkError.mockOnly }
    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { throw QuarkError.mockOnly }
    func cancelQRCodeLogin() {}
    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        CloudFilePage(files: [], page: 1, pageSize: 20, total: 0)
    }
    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        CloudFilePage(files: [], page: 1, pageSize: 20, total: 0)
    }
    func logout() async throws {}

    func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
        requestedFileIDs.append(fileID)
        if var results = scriptedResults[fileID], !results.isEmpty {
            let result = results.removeFirst()
            scriptedResults[fileID] = results
            return try result.get()
        }
        if let res = resources[fileID] {
            return res
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[fileID] = continuation
        }
    }

    func resumeContinuation(for fileID: String, with result: Result<PlaybackResource, Error>) {
        if let cont = pendingContinuations.removeValue(forKey: fileID) {
            cont.resume(with: result)
        }
    }
}
