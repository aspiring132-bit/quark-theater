import XCTest
@testable import QuarkTheater

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

        // Right from 选集 moves to 字幕
        let rightAction = PlayerInputReducer.reduce(state: state, direction: .right, seekInterval: 15)
        XCTAssertEqual(rightAction, .focusTarget(.drawerTab("字幕")))

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
        XCTAssertEqual(nextEpAction, .focusTarget(.episode("ep1")))

        // Up from content returns to tab
        let upFromContent = PlayerInputReducer.reduce(state: contentState, direction: .up, seekInterval: 10)
        XCTAssertEqual(upFromContent, .focusTarget(.drawerTab("选集")))
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
