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
}
