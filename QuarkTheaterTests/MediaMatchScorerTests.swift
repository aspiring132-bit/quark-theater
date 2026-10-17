import XCTest
@testable import QuarkTheater

final class MediaMatchScorerTests: XCTestCase {
    func testExactTitleAndYearRanksFirstWithHighConfidence() {
        let parsed = ParsedMediaName(title: "Dune", year: 2021, mediaType: .movie, seasonNumber: nil, episodeNumber: nil)
        let exact = TMDBSearchResult(id: 1, title: "Dune", name: nil, releaseDate: "2021-10-22", firstAirDate: nil,
                                     overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let wrong = TMDBSearchResult(id: 2, title: "Dune", name: nil, releaseDate: "1984-06-19", firstAirDate: nil,
                                     overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let ranked = MediaMatchScorer.rank([wrong, exact], for: parsed)
        XCTAssertEqual(ranked.first?.result.id, 1)
        XCTAssertTrue(MediaMatchScorer.mayAutoConfirm(ranked[0]))
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(ranked[1]))
    }
    func testUncertainTitleRequiresManualConfirmation() {
        let parsed = ParsedMediaName(title: "Unknown Film", year: nil, mediaType: .movie, seasonNumber: nil, episodeNumber: nil)
        let result = TMDBSearchResult(id: 7, title: "Unrelated", name: nil, releaseDate: nil, firstAirDate: nil,
                                      overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let match = try! XCTUnwrap(MediaMatchScorer.rank([result], for: parsed).first)
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(match))
    }
}
