import XCTest
@testable import QuarkTheater

@MainActor
final class CodexUpdateTests: XCTestCase {

    func testPlaybackURLPolicyAllowsOfflineFilesOnlyForUITestHarness() {
        let fileURL = URL(fileURLWithPath: "/tmp/quarktheater-fixture.mp4")
        let httpsURL = URL(string: "https://example.invalid/video.mp4")!
        let httpURL = URL(string: "http://example.invalid/video.mp4")!

        XCTAssertTrue(PlaybackCoordinator.isPlaybackURLAllowed(httpsURL, allowLocalUITestFile: false))
        XCTAssertFalse(PlaybackCoordinator.isPlaybackURLAllowed(fileURL, allowLocalUITestFile: false))
        XCTAssertTrue(PlaybackCoordinator.isPlaybackURLAllowed(fileURL, allowLocalUITestFile: true))
        XCTAssertFalse(PlaybackCoordinator.isPlaybackURLAllowed(httpURL, allowLocalUITestFile: true))
    }

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
        let engine = StubPlaybackEngine()
        let coordinator = PlaybackCoordinator(
            client: stubClient,
            accountID: "account-1",
            file: ep1,
            queue: [ep1, ep5],
            history: history,
            diagnostics: diagnostics,
            engine: engine
        )

        // 1. Initial play started for ep1 (stub holds ep1 continuation to simulate slow resolution)
        let ep1StartTask = Task { await coordinator.start() }
        for _ in 0..<20 {
            if stubClient.requestedFileIDs.contains("ep1") { break }
            await Task.yield()
        }
        XCTAssertEqual(stubClient.requestedFileIDs, ["ep1"])
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")

        // 2. User selects episode 5 in drawer (ep5 network in flight)
        let switchTask = coordinator.playFile(ep5, selectionOrdinal: 1, episodeNumber: 5)
        for _ in 0..<20 {
            if stubClient.requestedFileIDs.contains("ep5") { break }
            await Task.yield()
        }

        // 3. While ep5 is resolving: pending file is ep5, current file is still ep1
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep5")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertEqual(stubClient.requestedFileIDs, ["ep1", "ep5"])
        await diagnostics.waitForPendingOperations()
        XCTAssertTrue(diagnostics.records.contains { $0.event == .episodeSelectionRequested })
        XCTAssertFalse(diagnostics.records.contains { $0.event == .started })

        // 4. Outdated ep1 response resolves after ep5 was already requested
        stubClient.resumeContinuation(for: "ep1", with: .success(ep1Resource))
        _ = await ep1StartTask.result

        // Stale ep1 must NOT overwrite pending switch or current identity.
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep5")

        // 5. Ep5 network finishes and engine loads; ep1 stays committed and ep5 stays pending until .playing
        stubClient.resumeContinuation(for: "ep5", with: .success(ep5Resource))
        _ = await switchTask.value

        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep5")
        XCTAssertFalse(coordinator.isCurrentPlaybackStarted)
        XCTAssertTrue(coordinator.isPlaybackTransitionActive)
        await diagnostics.waitForPendingOperations()
        let selection = try XCTUnwrap(diagnostics.records.first { $0.event == .episodeSelectionRequested })
        XCTAssertEqual(selection.metadata["episodeOrdinal"], .int(1))
        XCTAssertEqual(selection.metadata["episodeNumber"], .int(5))
        XCTAssertFalse(diagnostics.records.contains { $0.event == .started })

        // 6. Engine emits .playing event, committing the playback transition to ep5
        engine.eventHandler?(.stateChanged(PlaybackSnapshot(
            generation: coordinator.generation,
            state: .playing,
            currentTime: 0,
            duration: 100,
            bufferedTime: 0,
            networkRate: 1024,
            hasVideoOutput: true,
            bufferedRanges: []
        )))

        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep5")
        XCTAssertNil(coordinator.pendingFile)
        XCTAssertTrue(coordinator.isCurrentPlaybackStarted)
        XCTAssertFalse(coordinator.isPlaybackTransitionActive)

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

    func testActiveAndPendingEpisodeIdentitiesRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-identity-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep2 = CloudFile(fileId: "ep2", parentId: "show", name: "Show.S01E02.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let stubClient = EpisodeSwitchStubClient()
        let coordinator = PlaybackCoordinator(client: stubClient, accountID: "account-1", file: ep1, queue: [ep1, ep2], history: history, diagnostics: diagnostics)

        // 1. Initial committed active file is ep1
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertEqual(coordinator.committedActiveFileID, "ep1")
        XCTAssertNil(coordinator.pendingFile)

        // 2. Select ep2 while in flight
        _ = coordinator.playFile(ep2, selectionOrdinal: 1, episodeNumber: 2)
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep2")
        // Committed identity must REMAIN ep1, never ep2 while pending
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertEqual(coordinator.committedActiveFileID, "ep1")
        XCTAssertFalse(coordinator.isEpisodePlaying(fileID: "ep2"))
        XCTAssertTrue(coordinator.isEpisodePlaying(fileID: "ep1"))
        XCTAssertTrue(coordinator.isEpisodePending(fileID: "ep2"))
        XCTAssertFalse(coordinator.isEpisodePending(fileID: "ep1"))
    }

    func testResourceResolutionAndLoadBeforeAndAfterPlaying() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-reg-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep2 = CloudFile(fileId: "ep2", parentId: "show", name: "Show.S01E02.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let stubClient = EpisodeSwitchStubClient()
        let engine = StubPlaybackEngine()
        let coordinator = PlaybackCoordinator(
            client: stubClient,
            accountID: "account-1",
            file: ep1,
            queue: [ep1, ep2],
            history: history,
            diagnostics: diagnostics,
            engine: engine
        )

        // 1. Initial launch state before any playback:
        // No active playing ID exists yet; must preserve fallback to ep1
        XCTAssertNil(coordinator.activePlayingFileID)
        XCTAssertEqual(coordinator.committedActiveFileID, "ep1")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertTrue(coordinator.isEpisodePlaying(fileID: "ep1"))
        XCTAssertFalse(coordinator.isEpisodePlaying(fileID: "ep2"))
        XCTAssertFalse(coordinator.isEpisodePending(fileID: "ep1"))
        XCTAssertFalse(coordinator.isEpisodePending(fileID: "ep2"))

        // Simulate ep1 reaching .playing
        engine.eventHandler?(.stateChanged(PlaybackSnapshot(
            generation: coordinator.generation,
            state: .playing,
            currentTime: 10,
            duration: 100,
            bufferedTime: 20,
            networkRate: 1024,
            hasVideoOutput: true,
            bufferedRanges: []
        )))
        XCTAssertEqual(coordinator.activePlayingFileID, "ep1")
        XCTAssertEqual(coordinator.committedActiveFileID, "ep1")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertTrue(coordinator.isEpisodePlaying(fileID: "ep1"))
        XCTAssertFalse(coordinator.isEpisodePlaying(fileID: "ep2"))

        // 2. Select ep2: triggers resolution
        _ = coordinator.playFile(ep2, selectionOrdinal: 1, episodeNumber: 2)

        // PHASE A: During resource resolution (network request in-flight)
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep2")
        XCTAssertEqual(coordinator.activePlayingFileID, "ep1")
        XCTAssertEqual(coordinator.committedActiveFileID, "ep1")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertTrue(coordinator.isEpisodePlaying(fileID: "ep1"))
        XCTAssertFalse(coordinator.isEpisodePlaying(fileID: "ep2"), "ep2 must NOT be marked playing while resolving resource")
        XCTAssertTrue(coordinator.isEpisodePending(fileID: "ep2"))
        XCTAssertFalse(coordinator.isEpisodePending(fileID: "ep1"))

        // PHASE B: Resource resolution completes, engine loads, before .playing (e.g. .loading or .buffering)
        let resource2 = PlaybackResource(
            fileID: "ep2",
            url: URL(string: "https://example.com/ep2.mp4")!,
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )
        stubClient.resumeContinuation(for: "ep2", with: .success(resource2))
        // Yield so resolveAndPlay continuation executes through to engine.load
        await Task.yield()

        // Engine receives load, emits .loading for the new generation
        engine.eventHandler?(.stateChanged(PlaybackSnapshot(
            generation: coordinator.generation,
            state: .loading,
            currentTime: 0,
            duration: 0,
            bufferedTime: 0,
            networkRate: 0,
            hasVideoOutput: false,
            bufferedRanges: []
        )))

        // Crucial regression check: after resolution/load, BEFORE .playing:
        // pendingFile must still be ep2, committed must still be ep1, ep2 is NOT playing!
        XCTAssertEqual(coordinator.pendingFile?.fileId, "ep2")
        XCTAssertEqual(coordinator.activePlayingFileID, "ep1")
        XCTAssertEqual(coordinator.committedActiveFileID, "ep1")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep1")
        XCTAssertTrue(coordinator.isEpisodePlaying(fileID: "ep1"))
        XCTAssertFalse(coordinator.isEpisodePlaying(fileID: "ep2"), "ep2 must NOT be marked playing while loading before .playing")
        XCTAssertTrue(coordinator.isEpisodePending(fileID: "ep2"))

        // PHASE C: Engine reaches committed playback state (.playing)
        engine.eventHandler?(.stateChanged(PlaybackSnapshot(
            generation: coordinator.generation,
            state: .playing,
            currentTime: 0,
            duration: 120,
            bufferedTime: 5,
            networkRate: 2048,
            hasVideoOutput: true,
            bufferedRanges: []
        )))

        // Now committed identity has transitioned to ep2!
        XCTAssertNil(coordinator.pendingFile)
        XCTAssertEqual(coordinator.activePlayingFileID, "ep2")
        XCTAssertEqual(coordinator.committedActiveFileID, "ep2")
        XCTAssertEqual(coordinator.currentPlayingFile.fileId, "ep2")
        XCTAssertTrue(coordinator.isEpisodePlaying(fileID: "ep2"))
        XCTAssertFalse(coordinator.isEpisodePlaying(fileID: "ep1"))
        XCTAssertFalse(coordinator.isEpisodePending(fileID: "ep2"))
    }

    func testIntroSeekRetryIsBoundedAndAvoidsRepeatedDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-skip-diag-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let stubClient = EpisodeSwitchStubClient()
        let engine = StubPlaybackEngine()
        engine.shouldAcceptSeek = false // Simulate not seekable
        let coordinator = PlaybackCoordinator(
            client: stubClient,
            accountID: "account-1",
            file: ep1,
            queue: [ep1],
            history: history,
            diagnostics: diagnostics,
            engine: engine
        )

        coordinator.setMarkersForTesting(ResolvedEpisodeMarkers(
            intro: PlaybackSegmentRange(startSeconds: 10, endSeconds: 90),
            outro: nil
        ), duration: 1000)

        // Trigger skip intro
        coordinator.skipIntro()
        XCTAssertEqual(coordinator.introSkipStatus, .pending(target: 91.0))

        // Wait for bounded retries to finish (max 3 attempts with 300ms sleep = ~900ms)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        // Must retain visible failure state
        if case .failed(let msg) = coordinator.introSkipStatus {
            XCTAssertTrue(msg.contains("重试"))
        } else {
            XCTFail("Expected .failed status after bounded retries, got \(coordinator.introSkipStatus)")
        }

        // Must bound seek attempts to at most 3
        XCTAssertLessThanOrEqual(engine.seekCallCount, 3)

        // Verify diagnostic logs: only ONE action-level seek log recorded, no diagnostic spam
        let records = await diagnostics.store.recent()
        let seekRecords = records.filter { $0.event == .playbackSeek }
        XCTAssertEqual(seekRecords.count, 1, "Must record only one action-level seek log for skipIntro")
    }

    func testIntroSkipTargetCalculationPastMarkerEndClampedToDuration() {
        let target = PlaybackCoordinator.introSkipTarget(
            introEndSeconds: 85.0,
            duration: 120.0
        )
        // Slightly past marker end (85 + 1.0 = 86.0), clamped to duration
        XCTAssertEqual(target, 86.0)

        // Clamped to duration
        let clampedTarget = PlaybackCoordinator.introSkipTarget(
            introEndSeconds: 119.5,
            duration: 120.0
        )
        XCTAssertEqual(clampedTarget, 120.0)
    }

    func testIntroSkipPendingStateAndCancellationOnGenerationChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-skip-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let ep1 = CloudFile(fileId: "ep1", parentId: "show", name: "Show.S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep2 = CloudFile(fileId: "ep2", parentId: "show", name: "Show.S01E02.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let stubClient = EpisodeSwitchStubClient()
        let engine = StubPlaybackEngine()
        let coordinator = PlaybackCoordinator(client: stubClient, accountID: "account-1", file: ep1, queue: [ep1, ep2], history: history, diagnostics: diagnostics, engine: engine)

        coordinator.setMarkersForTesting(ResolvedEpisodeMarkers(
            intro: PlaybackSegmentRange(startSeconds: 10, endSeconds: 90),
            outro: nil
        ), duration: 1000)

        coordinator.skipIntro()
        XCTAssertEqual(coordinator.introSkipStatus, .pending(target: 91.0))

        // On generation change / episode switch, pending skip MUST be cancelled and reset to idle
        coordinator.playFile(ep2)
        XCTAssertEqual(coordinator.introSkipStatus, .idle)
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

    @MainActor
    func testPlaybackQueueIncludesResumeFileWhenNotInCurrentSeason() {
        func makeEp(season: Int, episode: Int) -> (MediaItem, CloudFile, ParsedMediaName) {
            let id = "s\(season)e\(episode)"
            let item = MediaItem(id: id, fileId: id, mediaType: .series, title: "Show", seasonNumber: season, episodeNumber: episode)
            let file = CloudFile(fileId: id, parentId: "s\(season)", name: String(format: "S%02dE%02d.mp4", season, episode), size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
            let parsed = ParsedMediaName(title: "Show", mediaType: .series, seasonNumber: season, episodeNumber: episode)
            return (item, file, parsed)
        }

        let season1Episodes = (1...6).map { makeEp(season: 1, episode: $0) }
        let season2Episodes = (1...2).map { makeEp(season: 2, episode: $0) }
        let allEpisodes = season1Episodes + season2Episodes

        let targetE6 = season1Episodes[5].1 // S1E6 file
        XCTAssertEqual(targetE6.fileId, "s1e6")

        // When currently displayed season is Season 2, but resume target is S1E6 (outside displayed season):
        let queue = MediaItemDetailScreen.playbackQueue(
            for: targetE6,
            episodes: season2Episodes,
            allEpisodes: allEpisodes
        )
        // Queue MUST contain all episodes of Season 1, including target E6, preserving season alignment
        XCTAssertEqual(queue.map(\.fileId), ["s1e1", "s1e2", "s1e3", "s1e4", "s1e5", "s1e6"])
        XCTAssertTrue(queue.contains(where: { $0.fileId == targetE6.fileId }), "Target E6 must be present in queue")
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

    // MARK: - 7. EpisodeResumeResolver & Safe Diagnostics Tests
    func testEpisodeResumeResolverSelectsMostRecentUncompletedEpisode() {
        let ep1File = CloudFile(fileId: "f1", parentId: "0", name: "S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep5File = CloudFile(fileId: "f5", parentId: "0", name: "S01E05.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let item1 = MediaItem(id: "f1", fileId: "f1", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 1)
        let item5 = MediaItem(id: "f5", fileId: "f5", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 5)
        let parsed1 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 1)
        let parsed5 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 5)
        let episodes = [(item1, ep1File, parsed1), (item5, ep5File, parsed5)]

        let date1 = Date(timeIntervalSince1970: 1000)
        let date5 = Date(timeIntervalSince1970: 5000)
        let history1 = WatchHistory(accountId: "acc", fileId: "f1", fileName: "S01E01.mp4", positionSeconds: 10, durationSeconds: 1000, lastWatchedAt: date1, completed: false)
        let history5 = WatchHistory(accountId: "acc", fileId: "f5", fileName: "S01E05.mp4", positionSeconds: 500, durationSeconds: 1000, lastWatchedAt: date5, completed: false)
        let historyByFileID = ["f1": history1, "f5": history5]

        let resolved = EpisodeResumeResolver.resolve(episodes: episodes, historyByFileID: historyByFileID, isSeries: true)
        XCTAssertEqual(resolved?.1.fileId, "f5", "Should pick S1E5 because its lastWatchedAt is newer, even though S1E1 also has incomplete progress")
    }

    func testEpisodeResumeResolverAdvancesToSubsequentEpisodeWhenLatestIsCompleted() {
        let ep1File = CloudFile(fileId: "f1", parentId: "0", name: "S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep2File = CloudFile(fileId: "f2", parentId: "0", name: "S01E02.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let item1 = MediaItem(id: "f1", fileId: "f1", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 1)
        let item2 = MediaItem(id: "f2", fileId: "f2", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 2)
        let parsed1 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 1)
        let parsed2 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 2)
        let episodes = [(item1, ep1File, parsed1), (item2, ep2File, parsed2)]

        let history1 = WatchHistory(accountId: "acc", fileId: "f1", fileName: "S01E01.mp4", positionSeconds: 980, durationSeconds: 1000, lastWatchedAt: Date(), completed: true)
        let historyByFileID = ["f1": history1]

        let resolved = EpisodeResumeResolver.resolve(episodes: episodes, historyByFileID: historyByFileID, isSeries: true)
        XCTAssertEqual(resolved?.1.fileId, "f2", "When latest watched episode is completed, should advance to subsequent episode (S1E2)")
    }

    func testEpisodeResumeResolverFallsBackToFirstEpisodeWhenNoHistory() {
        let ep1File = CloudFile(fileId: "f1", parentId: "0", name: "S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let item1 = MediaItem(id: "f1", fileId: "f1", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 1)
        let parsed1 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 1)
        let episodes = [(item1, ep1File, parsed1)]

        let resolved = EpisodeResumeResolver.resolve(episodes: episodes, historyByFileID: [:], isSeries: true)
        XCTAssertEqual(resolved?.1.fileId, "f1")
    }

    func testEpisodeResumeResolverReturnsLastEpisodeWhenLatestWatchedIsLastEpisodeAndCompleted() {
        let ep1File = CloudFile(fileId: "f1", parentId: "0", name: "S01E01.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep2File = CloudFile(fileId: "f2", parentId: "0", name: "S01E02.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let ep3File = CloudFile(fileId: "f3", parentId: "0", name: "S01E03.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let item1 = MediaItem(id: "f1", fileId: "f1", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 1)
        let item2 = MediaItem(id: "f2", fileId: "f2", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 2)
        let item3 = MediaItem(id: "f3", fileId: "f3", mediaType: .series, title: "Test", year: 2024, tmdbId: 1, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 1, rating: nil, genreIDs: [], sourceType: .quark, seasonNumber: 1, episodeNumber: 3)
        let parsed1 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 1)
        let parsed2 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 2)
        let parsed3 = ParsedMediaName(title: "Test", year: 2024, mediaType: .series, seasonNumber: 1, episodeNumber: 3)
        let episodes = [(item1, ep1File, parsed1), (item2, ep2File, parsed2), (item3, ep3File, parsed3)]

        let history3 = WatchHistory(accountId: "acc", fileId: "f3", fileName: "S01E03.mp4", positionSeconds: 1000, durationSeconds: 1000, lastWatchedAt: Date(), completed: true)
        let historyByFileID = ["f3": history3]

        let resolved = EpisodeResumeResolver.resolve(episodes: episodes, historyByFileID: historyByFileID, isSeries: true)
        XCTAssertEqual(resolved?.1.fileId, "f3", "When latest watched episode is the final episode and completed, must stay on the final episode as conservative fallback and not jump back to S1E1")
    }

    func testEpisodeSelectionAndPlaybackStartedShareCorrelationIDAndDoNotLeakSecrets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-coordinator-diag-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: root))
        let history = try HistoryRepository(url: root.appendingPathComponent("history.sqlite"))
        let engine = StubPlaybackEngine()
        let stubClient = EpisodeSwitchStubClient()

        let ep5 = CloudFile(fileId: "ep5", parentId: "show", name: "Show.S01E05.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let coordinator = PlaybackCoordinator(
            client: stubClient,
            accountID: "account-1",
            file: ep5,
            queue: [ep5],
            history: history,
            diagnostics: diagnostics,
            engine: engine
        )

        let startTask = Task { await coordinator.start() }
        for _ in 0..<20 {
            if stubClient.requestedFileIDs.contains("ep5") { break }
            await Task.yield()
        }

        // 1. Verify lastRequestedPlaybackFileID records the requested fileId
        XCTAssertEqual(coordinator.lastRequestedPlaybackFileID, "ep5")

        // 2. Supply resource and let start complete
        let resource = PlaybackResource(
            fileID: "ep5",
            url: URL(string: "https://pan.quark.cn/stream/ep5.mp4?token=secret123&cookie=auth456")!,
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )
        stubClient.resumeContinuation(for: "ep5", with: .success(resource))
        _ = await startTask.value

        // 3. Engine fires ready event to begin playback
        let snap = PlaybackSnapshot(
            generation: 1,
            state: .playing,
            currentTime: 0,
            duration: 100,
            bufferedTime: 10,
            networkRate: 1024,
            hasVideoOutput: true,
            bufferedRanges: []
        )
        engine.eventHandler?(.ready(snap))
        await diagnostics.waitForPendingOperations()

        // 4. Verify linkage: episodeSelectionRequested and started share the exact same correlationID
        let selectionRecord = try XCTUnwrap(diagnostics.records.first { $0.event == .episodeSelectionRequested })
        let startedRecord = try XCTUnwrap(diagnostics.records.first { $0.event == .started })

        XCTAssertNotNil(selectionRecord.correlationID)
        XCTAssertEqual(selectionRecord.correlationID, startedRecord.correlationID, "episodeSelectionRequested and playback started MUST share the same correlation ID")

        // 5. Verify no sensitive URLs, tokens or cookies leaked in diagnostic records
        for record in [selectionRecord, startedRecord] {
            for (key, val) in record.metadata {
                let str = String(describing: val)
                XCTAssertFalse(str.contains("secret123"), "Diagnostic metadata \(key) must not leak tokens")
                XCTAssertFalse(str.contains("auth456"), "Diagnostic metadata \(key) must not leak cookies")
                XCTAssertFalse(str.contains("pan.quark.cn"), "Diagnostic metadata \(key) must not leak streaming URLs")
            }
        }
    }

    // MARK: - 8. Speed & Hint Pill Policy Tests
    func testNetworkSpeedPolicyDoesNotClearSpeedOnBufferingOrLoading() {
        let engine = StubPlaybackEngine()
        let tempHistoryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-history-\(UUID()).sqlite")
        let history = try! HistoryRepository(url: tempHistoryURL)
        let coordinator = PlaybackCoordinator(
            client: EpisodeSwitchStubClient(),
            accountID: "acc-1",
            file: CloudFile(fileId: "f1", parentId: "0", name: "v.mp4", size: 100, fileExtension: "mp4", modifiedAt: nil, isDirectory: false),
            history: history,
            diagnostics: Diagnostics(),
            engine: engine
        )

        // Simulate real speed arriving via snapshot
        let currentGen = coordinator.snapshot.generation
        let snapWithSpeed = PlaybackSnapshot(
            generation: currentGen,
            state: .playing,
            currentTime: 10,
            duration: 100,
            bufferedTime: 20,
            networkRate: 2_097_152, // 2 MB/s
            hasVideoOutput: true,
            bufferedRanges: []
        )
        engine.eventHandler?(.stateChanged(snapWithSpeed))
        // Verify speed was recorded or formatted
        XCTAssertEqual(coordinator.networkSpeedText, "2.0 MB/s")

        // Diagnostic event with buffering state MUST NOT clear existing real speed
        let diagSnap = PlaybackDiagnosticSnapshot(
            generation: currentGen,
            mediaIdentifier: "test",
            state: .buffering,
            hasVideoOutput: true,
            decodedAudioBuffers: 0,
            lostAudioBuffers: 0,
            decodedVideoFrames: 0,
            lostVideoFrames: 0
        )
        engine.eventHandler?(.diagnostic(diagSnap))
        XCTAssertEqual(coordinator.networkSpeedText, "2.0 MB/s", "Buffering diagnostic must not clear previously sampled real network speed")

        // Zero or non-positive networkRate resets networkSpeedText to avoid displaying stale speed samples
        let snapWithoutSpeed = PlaybackSnapshot(
            generation: currentGen,
            state: .playing,
            currentTime: 12,
            duration: 100,
            bufferedTime: 20,
            networkRate: 0,
            hasVideoOutput: true,
            bufferedRanges: []
        )
        engine.eventHandler?(.stateChanged(snapWithoutSpeed))
        XCTAssertEqual(coordinator.networkSpeedText, "", "Zero networkRate must clear stale speed text")
    }

    func testPlayerScreenHintDismissDurationIsThreeSeconds() {
        XCTAssertEqual(PlayerScreen.hintDismissDurationSeconds, 3.0)
    }

    // MARK: - 9. HUD, Scrubber & Throughput Policy Tests
    func testPlayerTimeFormatterDurationAndCurrentTimeWhenUnknown() {
        // When duration is unknown (<= 0), formatDuration must return "--:--"
        XCTAssertEqual(PlayerTimeFormatter.formatDuration(0), "--:--")
        XCTAssertEqual(PlayerTimeFormatter.formatDuration(-1), "--:--")
        XCTAssertEqual(PlayerTimeFormatter.formatDuration(.nan), "--:--")

        // When duration is unknown and current time is 0, formatCurrentTime must return "--:--"
        XCTAssertEqual(PlayerTimeFormatter.formatCurrentTime(0, duration: 0), "--:--")
        XCTAssertEqual(PlayerTimeFormatter.formatCurrentTime(0, duration: -1), "--:--")

        // Established times
        XCTAssertEqual(PlayerTimeFormatter.formatDuration(125), "02:05")
        XCTAssertEqual(PlayerTimeFormatter.formatDuration(3665), "01:01:05")
        XCTAssertEqual(PlayerTimeFormatter.formatCurrentTime(15, duration: 125), "00:15")
        XCTAssertEqual(PlayerTimeFormatter.formatCurrentTime(3600, duration: 3665), "01:00:00")

        // Diff formatting
        XCTAssertEqual(PlayerTimeFormatter.formatTargetDiff(pending: 20, current: 0), "+20s")
        XCTAssertEqual(PlayerTimeFormatter.formatTargetDiff(pending: 10, current: 25), "-15s")
        XCTAssertEqual(PlayerTimeFormatter.formatTargetDiff(pending: 10, current: 10), "+0s")
    }

    func testPlayerScrubberGeometryPolicyDurationZeroDoesNotMapTargetToOneHundredPercent() {
        // When duration <= 0, targetFraction must NOT clamp to 1.0 (100%)
        let zeroDurationTarget = PlayerScrubberGeometryPolicy.targetFraction(target: 20, duration: 0)
        XCTAssertNil(zeroDurationTarget, "When duration <= 0, targetFraction must be nil so target is not mapped to 100%")

        let zeroDurationPlayed = PlayerScrubberGeometryPolicy.playedFraction(current: 20, duration: 0)
        XCTAssertEqual(zeroDurationPlayed, 0, "Played fraction must be 0 when duration is 0")

        let zeroDurationBuffers = PlayerScrubberGeometryPolicy.bufferedFractions(
            ranges: [PlaybackTimeRange(start: 0, end: 10)],
            duration: 0
        )
        XCTAssertTrue(zeroDurationBuffers.isEmpty)

        // With valid duration
        let validTarget = PlayerScrubberGeometryPolicy.targetFraction(target: 50, duration: 100)
        XCTAssertEqual(validTarget, 0.5)

        let validPlayed = PlayerScrubberGeometryPolicy.playedFraction(current: 25, duration: 100)
        XCTAssertEqual(validPlayed, 0.25)

        let validBuffers = PlayerScrubberGeometryPolicy.bufferedFractions(
            ranges: [PlaybackTimeRange(start: 0, end: 30), PlaybackTimeRange(start: 60, end: 80)],
            duration: 100
        )
        XCTAssertEqual(validBuffers.count, 2)
        XCTAssertEqual(validBuffers[0], ScrubberSegment(startFraction: 0.0, endFraction: 0.3))
        XCTAssertEqual(validBuffers[1], ScrubberSegment(startFraction: 0.6, endFraction: 0.8))
    }

    func testPlayerSpeedBadgePolicyFormatting() {
        // Buffering without sample must never say "暂无数据"
        let bufferingNoSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: true, isLoading: false, isSeeking: false, speedText: "")
        XCTAssertEqual(bufferingNoSpeed, "缓冲中…")
        XCTAssertFalse(bufferingNoSpeed?.contains("暂无数据") == true)

        let bufferingWithSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: true, isLoading: false, isSeeking: false, speedText: "2.4 MB/s")
        XCTAssertEqual(bufferingWithSpeed, "缓冲中 · 2.4 MB/s")

        // Loading without sample
        let loadingNoSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: false, isLoading: true, isSeeking: false, speedText: "")
        XCTAssertEqual(loadingNoSpeed, "正在加载…")
        XCTAssertFalse(loadingNoSpeed?.contains("暂无数据") == true)

        let loadingWithSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: false, isLoading: true, isSeeking: false, speedText: "1.2 MB/s")
        XCTAssertEqual(loadingWithSpeed, "正在加载 · 1.2 MB/s")

        // Seek-only without sample: must display "正在跳转…", never "暂无数据"
        let seekOnlyNoSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: false, isLoading: false, isSeeking: true, speedText: "")
        XCTAssertEqual(seekOnlyNoSpeed, "正在跳转…")
        XCTAssertFalse(seekOnlyNoSpeed?.contains("暂无数据") == true)

        // Seek-only with sample: displays speed
        let seekOnlyWithSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: false, isLoading: false, isSeeking: true, speedText: "3.5 MB/s")
        XCTAssertEqual(seekOnlyWithSpeed, "3.5 MB/s")

        // Idle / Normal playback (not buffering, not loading, not seeking): badge MUST be hidden (nil)
        let idleNoSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: false, isLoading: false, isSeeking: false, speedText: "")
        XCTAssertNil(idleNoSpeed, "Badge must not be shown during idle/normal playback without speed")

        let idleWithSpeed = PlayerSpeedBadgePolicy.badgeText(isBuffering: false, isLoading: false, isSeeking: false, speedText: "1.2 MB/s")
        XCTAssertNil(idleWithSpeed, "Badge must not be shown during idle/normal playback even if speed is present")
    }

    func testProxyNetworkThroughputTrackerSamplesThroughput() {
        let tracker = VLCOriginHTTPProxy.NetworkThroughputTracker(windowSeconds: 2.0)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(0.5)

        tracker.record(bytes: 500_000, at: t0)
        tracker.record(bytes: 500_000, at: t1)

        let rate = tracker.currentBytesPerSecond(at: t1)
        XCTAssertNotNil(rate)
        if let rate {
            // 1,000,000 bytes over 0.5s = ~2,000,000 bytes/sec
            XCTAssertEqual(rate, 2_000_000, accuracy: 1.0)
        }
    }

    func testProxyVODTimelineCalculatesTotalDuration() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:9.009,
        segment1.ts
        #EXTINF:8.5,
        segment2.ts
        #EXT-X-ENDLIST
        """
        let url = URL(string: "https://example.com/vod.m3u8")!
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: url)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.totalDuration ?? 0, 17.509, accuracy: 0.001)
        XCTAssertEqual(timeline?.segments.count, 2)
    }
}

@MainActor
private final class StubPlaybackEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var snapshot: PlaybackSnapshot = .idle()
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var seekCallCount: Int = 0
    var shouldAcceptSeek: Bool = true
    var loadedResources: [PlaybackResource] = []

    func attachSurface(_ surface: UIView?) {}
    func load(_ resource: PlaybackResource, generation: Int) {
        loadedResources.append(resource)
    }
    func play() {}
    func pause() {}
    func stop() {}
    @discardableResult
    func seek(to seconds: TimeInterval) -> Bool {
        seekCallCount += 1
        return shouldAcceptSeek
    }
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
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
