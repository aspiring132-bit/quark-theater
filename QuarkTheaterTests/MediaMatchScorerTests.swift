import XCTest
@testable import QuarkTheater

final class MediaMatchScorerTests: XCTestCase {
    func testBuiltInAliasesAreExactAndStable() {
        XCTAssertEqual(MediaAliasResolver.variants(for: "蜘蛛侠"), ["蜘蛛侠"])
        XCTAssertEqual(MediaAliasResolver.variants(for: "蛛丝"), ["蛛丝", "蜘蛛侠"])
        XCTAssertFalse(MediaAliasResolver.variants(for: "蜘蛛侠").contains("蜘蛛侠侠"))
        XCTAssertEqual(MediaAliasResolver.variants(for: "蛛丝"), MediaAliasResolver.variants(for: "蛛丝"))
    }
    func testExactTitleAndYearRanksFirstWithHighConfidence() {
        let parsed = ParsedMediaName(title: "Dune", year: 2021, mediaType: .movie, seasonNumber: nil,
                                     episodeNumber: nil, inferredFromParent: false)
        let exact = TMDBSearchResult(id: 1, title: "Dune", name: nil, originalTitle: nil, originalName: nil,
                                     releaseDate: "2021-10-22", firstAirDate: nil,
                                     overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let wrong = TMDBSearchResult(id: 2, title: "Dune", name: nil, originalTitle: nil, originalName: nil,
                                     releaseDate: "1984-06-19", firstAirDate: nil,
                                     overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let ranked = MediaMatchScorer.rank([wrong, exact], for: parsed)
        XCTAssertEqual(ranked.first?.result.id, 1)
        XCTAssertTrue(MediaMatchScorer.mayAutoConfirm(ranked[0]))
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(ranked[1]))
        XCTAssertTrue(MediaMatchScorer.mayAutoConfirm(ranked))
    }
    func testUncertainTitleRequiresManualConfirmation() {
        let parsed = ParsedMediaName(title: "Unknown Film", year: nil, mediaType: .movie, seasonNumber: nil,
                                     episodeNumber: nil, inferredFromParent: false)
        let result = TMDBSearchResult(id: 7, title: "Unrelated", name: nil, originalTitle: nil, originalName: nil,
                                      releaseDate: nil, firstAirDate: nil,
                                      overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let match = try! XCTUnwrap(MediaMatchScorer.rank([result], for: parsed).first)
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(match))
    }

    func testIncompatibleEndpointResultCannotWinSeriesMatch() {
        let parsed = ParsedMediaName(title: "Dune", year: nil, mediaType: .series, seasonNumber: 1,
                                     episodeNumber: 1, inferredFromParent: false)
        let movie = TMDBSearchResult(id: 1, title: "Dune", name: nil, originalTitle: nil, originalName: nil,
                                     releaseDate: "2021-10-22", firstAirDate: nil, overview: nil,
                                     posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil,
                                     sourceMediaType: .movie)
        let tv = TMDBSearchResult(id: 2, title: nil, name: "Dune", originalTitle: nil, originalName: nil,
                                  releaseDate: nil, firstAirDate: "2021-01-01", overview: nil,
                                  posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil,
                                  sourceMediaType: .series)
        let ranked = MediaMatchScorer.rank([movie, tv], for: parsed)
        XCTAssertEqual(ranked.map(\.result.id), [2])
    }

    func testStrongTopWithCloseRunnerUpNeedsConfirmation() {
        let parsed = ParsedMediaName(title: "Dune", year: 2021, mediaType: .movie, seasonNumber: nil,
                                     episodeNumber: nil, inferredFromParent: false)
        let first = TMDBSearchResult(id: 1, title: "Dune", name: nil, originalTitle: nil, originalName: nil,
                                     releaseDate: "2021-10-22", firstAirDate: nil, overview: nil,
                                     posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        let second = TMDBSearchResult(id: 2, title: "Dune", name: nil, originalTitle: nil, originalName: nil,
                                      releaseDate: "2021-10-23", firstAirDate: nil, overview: nil,
                                      posterPath: nil, backdropPath: nil, voteAverage: nil, genreIDs: nil)
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(MediaMatchScorer.rank([first, second], for: parsed)))
    }

    func testExactSeriesWithEpisodeContextCanAutoConfirmWithoutYear() {
        let parsed = ParsedMediaName(title: "权力的游戏", year: nil, mediaType: .series,
                                     seasonNumber: 1, episodeNumber: 1, inferredFromParent: true)
        let result = TMDBSearchResult(id: 1399, title: nil, name: "权力的游戏", originalTitle: nil,
                                      originalName: nil, releaseDate: nil, firstAirDate: "2011-04-17",
                                      overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil,
                                      genreIDs: nil, sourceMediaType: .series)
        let ranked = MediaMatchScorer.rank([result], for: parsed)
        XCTAssertTrue(MediaMatchScorer.mayAutoConfirm(ranked))
    }

    func testUnboundAliasCannotAutoConfirm() {
        let parsed = ParsedMediaName(title: "蛛丝", year: nil, mediaType: .movie,
                                     seasonNumber: nil, episodeNumber: nil, inferredFromParent: false)
        let result = TMDBSearchResult(id: 1, title: "Spider-Man", name: nil, originalTitle: nil,
                                      originalName: nil, releaseDate: nil, firstAirDate: nil,
                                      overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil,
                                      genreIDs: nil)
        let ranked = MediaMatchScorer.rank([result], for: parsed)
        XCTAssertEqual(ranked.first?.result.id, 1)
        XCTAssertLessThan(ranked.first?.confidence ?? 1, 0.95)
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(ranked))
    }

    func testLearnedAliasOnlyRaisesMatchingConfirmedTMDBIdentity() {
        let parsed = ParsedMediaName(title: "Quan You", year: nil, mediaType: .series,
                                     seasonNumber: 1, episodeNumber: 1, inferredFromParent: false)
        let matching = TMDBSearchResult(id: 1399, title: nil, name: "权力的游戏", originalTitle: nil,
                                        originalName: nil, releaseDate: nil, firstAirDate: "2011-01-01",
                                        overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil,
                                        genreIDs: nil, sourceMediaType: .series)
        let different = TMDBSearchResult(id: 9999, title: nil, name: "权力的游戏", originalTitle: nil,
                                          originalName: nil, releaseDate: nil, firstAirDate: "2020-01-01",
                                          overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil,
                                          genreIDs: nil, sourceMediaType: .series)
        let alias = LearnedAlias(accountID: "account-a", mediaType: .series, sourceTitle: "quan you",
                                 canonicalTitle: "权力的游戏", tmdbID: 1399, updatedAt: Date())
        let ranked = MediaMatchScorer.rank([different, matching], for: parsed, learnedAliasRecords: [alias])
        XCTAssertEqual(ranked.first?.result.id, 1399)
        XCTAssertEqual(ranked.first?.confidence, 0.95)
        XCTAssertLessThan(ranked.last?.confidence ?? 1, 0.95)
        XCTAssertTrue(MediaMatchScorer.mayAutoConfirm(ranked))
    }

    func testLearnedAliasForDifferentIdentityCannotAutoConfirm() {
        let parsed = ParsedMediaName(title: "Quan You", year: nil, mediaType: .series,
                                     seasonNumber: 1, episodeNumber: 1, inferredFromParent: false)
        let result = TMDBSearchResult(id: 1399, title: nil, name: "权力的游戏", originalTitle: nil,
                                      originalName: nil, releaseDate: nil, firstAirDate: "2011-01-01",
                                      overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil,
                                      genreIDs: nil, sourceMediaType: .series)
        let aliasForDifferentIdentity = LearnedAlias(accountID: "account-a", mediaType: .series,
                                                      sourceTitle: "quan you", canonicalTitle: "权力的游戏",
                                                      tmdbID: 9999, updatedAt: Date())
        let ranked = MediaMatchScorer.rank([result], for: parsed,
                                           learnedAliasRecords: [aliasForDifferentIdentity])
        XCTAssertLessThan(ranked.first?.confidence ?? 1, 0.95)
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(ranked))
    }

    func testBuiltInAliasRemainsConservative() {
        let parsed = ParsedMediaName(title: "蛛丝", year: nil, mediaType: .movie,
                                     seasonNumber: nil, episodeNumber: nil, inferredFromParent: false)
        let result = TMDBSearchResult(id: 1, title: "蜘蛛侠", name: nil, originalTitle: nil,
                                      originalName: nil, releaseDate: nil, firstAirDate: nil,
                                      overview: nil, posterPath: nil, backdropPath: nil, voteAverage: nil,
                                      genreIDs: nil)
        let ranked = MediaMatchScorer.rank([result], for: parsed)
        XCTAssertFalse(MediaMatchScorer.mayAutoConfirm(ranked))
    }

    @MainActor
    func testBatchRematchParsesEachEpisodeIndependently() {
        let existing = MediaItem(id: "show", fileId: "show", mediaType: .series,
                                 title: "权力的游戏", matchConfidence: 0.99,
                                 seasonNumber: 1, episodeNumber: 1)
        let first = CloudFile(fileId: "01", parentId: "s01", name: "01.mp4", size: 1,
                              fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let second = CloudFile(fileId: "02", parentId: "s01", name: "02.mp4", size: 1,
                               fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let firstParsed = TMDBMatchScreen.parsedMetadata(for: first, candidate: nil, existingItem: existing)
        let secondParsed = TMDBMatchScreen.parsedMetadata(for: second, candidate: nil, existingItem: existing)
        XCTAssertEqual(firstParsed.episodeNumber, 1)
        XCTAssertEqual(secondParsed.episodeNumber, 2)
        XCTAssertNotEqual(firstParsed.episodeNumber, secondParsed.episodeNumber)

        let firstCandidate = ScannedMediaCandidate(file: first,
            parsedName: ParsedMediaName(title: "权力的游戏", year: nil, mediaType: .series,
                                        seasonNumber: 1, episodeNumber: 1, inferredFromParent: true),
            parentFolderName: "S01", ancestorFolderName: "权力的游戏")
        let secondFile = CloudFile(fileId: "03", parentId: "s02", name: "01.mp4", size: 1,
                                   fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let secondCandidate = ScannedMediaCandidate(file: secondFile,
            parsedName: ParsedMediaName(title: "权力的游戏", year: nil, mediaType: .series,
                                        seasonNumber: 2, episodeNumber: 1, inferredFromParent: true),
            parentFolderName: "S02", ancestorFolderName: "权力的游戏")
        XCTAssertEqual(TMDBMatchScreen.parsedMetadata(for: first, candidate: firstCandidate, existingItem: existing).seasonNumber, 1)
        XCTAssertEqual(TMDBMatchScreen.parsedMetadata(for: secondFile, candidate: secondCandidate, existingItem: existing).seasonNumber, 2)
    }

    @MainActor
    func testRematchSynthesizesMissingCandidatesWithoutLosingCrossSeasonMetadata() {
        let existing = MediaItem(id: "show", fileId: "show", mediaType: .series,
                                 title: "权力的游戏", matchConfidence: 0.99,
                                 seasonNumber: 1, episodeNumber: 1)
        let first = CloudFile(fileId: "s01e01", parentId: "s01", name: "01.mp4", size: 1,
                              fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let second = CloudFile(fileId: "s02e01", parentId: "s02", name: "01.mp4", size: 1,
                               fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let firstParsed = ParsedMediaName(title: existing.title, year: nil, mediaType: .series,
                                          seasonNumber: 1, episodeNumber: 1, inferredFromParent: true)
        let secondParsed = ParsedMediaName(title: existing.title, year: nil, mediaType: .series,
                                           seasonNumber: 2, episodeNumber: 1, inferredFromParent: true)

        let firstCandidate = TMDBMatchScreen.rematchCandidate(for: first, parsedName: firstParsed, candidates: [])
        let secondCandidate = TMDBMatchScreen.rematchCandidate(for: second, parsedName: secondParsed, candidates: [firstCandidate])

        XCTAssertEqual(TMDBMatchScreen.parsedMetadata(for: first, candidate: firstCandidate, existingItem: existing).seasonNumber, 1)
        XCTAssertEqual(TMDBMatchScreen.parsedMetadata(for: second, candidate: secondCandidate, existingItem: existing).seasonNumber, 2)
        XCTAssertEqual(TMDBMatchScreen.parsedMetadata(for: second, candidate: secondCandidate, existingItem: existing).episodeNumber, 1)
    }

    @MainActor
    func testDetailRematchBuildsPerFileCandidatesWhenScannerCandidatesAreMissing() {
        let seasonOne = MediaItem(id: "s01e01", fileId: "s01e01", mediaType: .series,
                                  title: "权力的游戏", matchConfidence: 0.99,
                                  seasonNumber: 1, episodeNumber: 1)
        let seasonTwo = MediaItem(id: "s02e01", fileId: "s02e01", mediaType: .series,
                                  title: "权力的游戏", matchConfidence: 0.99,
                                  seasonNumber: 2, episodeNumber: 1)

        let rematchCandidates = MediaItemDetailScreen.rematchCandidates(
            for: [seasonOne, seasonTwo], candidates: []
        )

        XCTAssertEqual(rematchCandidates.map(\.file.fileId), ["s01e01", "s02e01"])
        XCTAssertEqual(rematchCandidates.map(\.parsedName.seasonNumber), [1, 2])
        XCTAssertEqual(rematchCandidates.map(\.parsedName.episodeNumber), [1, 1])
    }
}
