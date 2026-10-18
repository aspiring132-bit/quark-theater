import XCTest
@testable import QuarkTheater

final class FilenameParserTests: XCTestCase {
    func testParsesDottedMovieNameYearAndQualitySuffix() {
        let parsed = FilenameParser.parse("Movie.Name.2024.2160p.mkv")
        XCTAssertEqual(parsed.title, "Movie Name")
        XCTAssertEqual(parsed.year, 2024)
        XCTAssertEqual(parsed.mediaType, .movie)
    }
    func testParsesMovieNameWithParenthesizedYear() {
        let parsed = FilenameParser.parse("Movie Name (2024).mp4")
        XCTAssertEqual(parsed.title, "Movie Name")
        XCTAssertEqual(parsed.year, 2024)
    }
    func testParsesSeasonEpisodeNotation() {
        let parsed = FilenameParser.parse("Series.S01E02.mkv")
        XCTAssertEqual(parsed.title, "Series")
        XCTAssertEqual(parsed.mediaType, .series)
        XCTAssertEqual(parsed.seasonNumber, 1)
        XCTAssertEqual(parsed.episodeNumber, 2)
    }
    func testParsesXNotation() {
        let parsed = FilenameParser.parse("Series Name.1x02.mp4")
        XCTAssertEqual(parsed.title, "Series Name")
        XCTAssertEqual(parsed.seasonNumber, 1)
        XCTAssertEqual(parsed.episodeNumber, 2)
    }

    func testBareEpisodeUsesNamedSeriesAndStrictSeasonFolder() {
        let parsed = FilenameParser.parse(
            "01.mp4",
            pathComponents: ["影视", "权力的游戏", "S01"],
            boundRootName: nil
        )

        XCTAssertEqual(parsed.title, "权力的游戏")
        XCTAssertEqual(parsed.mediaType, .series)
        XCTAssertEqual(parsed.seasonNumber, 1)
        XCTAssertEqual(parsed.episodeNumber, 1)
    }

    func testNamedBoundRootSuppliesSeriesContext() {
        let parsed = FilenameParser.parse(
            "03.mkv",
            pathComponents: ["S02"],
            boundRootName: "大西洋帝国"
        )

        XCTAssertEqual(parsed.title, "大西洋帝国")
        XCTAssertEqual(parsed.mediaType, .series)
        XCTAssertEqual(parsed.seasonNumber, 2)
        XCTAssertEqual(parsed.episodeNumber, 3)
    }

    func testBareNumberWithoutSeriesContextIsUnresolved() {
        let parsed = FilenameParser.parse("09.mp4", pathComponents: ["0"], boundRootName: nil)

        XCTAssertEqual(parsed.mediaType, .unknown)
        XCTAssertEqual(parsed.unresolvedReason, .missingSeriesContext)
        XCTAssertNotEqual(parsed.title, "09")
    }

    func testGenericFolderDoesNotBecomeSeriesTitle() {
        let parsed = FilenameParser.parse("01.mp4", pathComponents: ["Extras"], boundRootName: nil)

        XCTAssertEqual(parsed.mediaType, .unknown)
        XCTAssertEqual(parsed.unresolvedReason, .missingSeriesContext)
    }

    func testEmbeddedS01InTitleIsNotASeasonFolder() {
        let context = FilenameParser.extractShowAndSeason(fromPath: ["ShowS01Collection"])

        XCTAssertEqual(context.show, "ShowS01Collection")
        XCTAssertNil(context.season)
    }

    func testNearerSeriesFolderWinsOverBoundRootFallback() {
        let parsed = FilenameParser.parse("01.mp4", pathComponents: ["剧集分类", "真正的剧名", "S01"], boundRootName: "合集根目录")
        XCTAssertEqual(parsed.title, "真正的剧名")
        XCTAssertEqual(parsed.seasonNumber, 1)
        XCTAssertEqual(parsed.episodeNumber, 1)
    }

    func testHighCastleSeason4FolderAndBareEpisodes() {
        let parsed = FilenameParser.parse(
            "01.mp4",
            pathComponents: ["来自：分享", "G 高堡奇人S01~S04", "Season 04"],
            boundRootName: nil
        )
        XCTAssertEqual(parsed.title, "高堡奇人")
        XCTAssertEqual(parsed.mediaType, .series)
        XCTAssertEqual(parsed.seasonNumber, 4)
        XCTAssertEqual(parsed.episodeNumber, 1)
    }

    func testChineseNumeralSeasonExtraction() {
        let parsed = FilenameParser.parse(
            "10.mp4",
            pathComponents: ["高堡奇人", "第四季"],
            boundRootName: nil
        )
        XCTAssertEqual(parsed.title, "高堡奇人")
        XCTAssertEqual(parsed.mediaType, .series)
        XCTAssertEqual(parsed.seasonNumber, 4)
        XCTAssertEqual(parsed.episodeNumber, 10)
    }

    func testProjectHailMaryTitleAndObfuscationBypass() {
        let title = FilenameParser.folderTitle("挽救#J划 Project Hail Mary (2026)(1)")
        XCTAssertEqual(title, "挽救计划 Project Hail Mary")
    }
}
