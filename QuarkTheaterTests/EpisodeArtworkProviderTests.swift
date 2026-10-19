import Foundation
import XCTest
@testable import QuarkTheater

final class EpisodeArtworkProviderTests: XCTestCase {

    private func parsed(season: Int?, episode: Int?) -> ParsedMediaName {
        ParsedMediaName(title: "Demo", year: nil, mediaType: .series,
                        seasonNumber: season, episodeNumber: episode, inferredFromParent: false)
    }

    // MARK: - Resolver

    func testResolverOnlyEmitsFullyKnownSeasonAndEpisode() {
        let requests = EpisodeArtworkResolver.requests(
            seriesTMDBId: 100,
            metadataByFileID: [
                "file-a": parsed(season: 4, episode: 2),
                "file-b": parsed(season: 4, episode: nil), // unknown episode: never guess
                "file-c": parsed(season: nil, episode: 3), // unknown season: never guess
                "file-d": parsed(season: 1, episode: 1)
            ]
        )
        XCTAssertEqual(requests["file-a"], EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 2))
        XCTAssertEqual(requests["file-d"], EpisodeArtworkRequest(seasonNumber: 1, episodeNumber: 1))
        XCTAssertNil(requests["file-b"])
        XCTAssertNil(requests["file-c"])
    }

    func testResolverWithoutSeriesIDEmitsNothing() {
        let requests = EpisodeArtworkResolver.requests(
            seriesTMDBId: nil,
            metadataByFileID: ["file-a": parsed(season: 4, episode: 2)]
        )
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Per-file mapping

    func testEpisodeMapsToItsOwnStillRegardlessOfFileOrder() async {
        let provider = EpisodeArtworkProvider { key in
            XCTAssertEqual(key, EpisodeArtworkProvider.SeasonKey(seriesID: 100, seasonNumber: 4))
            return [1: "/ep1.jpg", 2: "/ep2.jpg", 3: nil]
        }
        // Drawer order differs from episode order on purpose.
        let requests: [String: EpisodeArtworkRequest] = [
            "file-ep2": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 2),
            "file-ep1": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 1),
            "file-ep3": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 3)
        ]
        let urls = await provider.stillURLs(seriesID: 100, requests: requests)
        XCTAssertEqual(urls["file-ep2"]?.absoluteString, "https://image.tmdb.org/t/p/w780/ep2.jpg")
        XCTAssertEqual(urls["file-ep1"]?.absoluteString, "https://image.tmdb.org/t/p/w780/ep1.jpg")
        // Episode 3 exists but has no still: no URL, caller falls back.
        XCTAssertNil(urls["file-ep3"])
    }

    func testEpisodeOutsideSeasonMapYieldsNoURL() async {
        let provider = EpisodeArtworkProvider { _ in [1: "/ep1.jpg"] }
        let urls = await provider.stillURLs(
            seriesID: 100,
            requests: ["file-x": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 77)]
        )
        XCTAssertNil(urls["file-x"])
    }

    // MARK: - Request bounding / caching

    func testOneSeasonFetchServesAllCardsAndIsCached() async {
        let counter = FetchCounter()
        let provider = EpisodeArtworkProvider { key in
            counter.increment()
            return [1: "/ep1.jpg", 2: "/ep2.jpg"]
        }
        let first = await provider.stillURLs(
            seriesID: 100,
            requests: [
                "a": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 1),
                "b": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 2)
            ]
        )
        let second = await provider.stillURLs(
            seriesID: 100,
            requests: ["a": EpisodeArtworkRequest(seasonNumber: 4, episodeNumber: 1)]
        )
        XCTAssertEqual(counter.value, 1, "Repeated access must not issue a second season request")
        XCTAssertEqual(first["b"]?.absoluteString, "https://image.tmdb.org/t/p/w780/ep2.jpg")
        XCTAssertEqual(second["a"]?.absoluteString, "https://image.tmdb.org/t/p/w780/ep1.jpg")
    }

    func testConcurrentAccessSharesInFlightSeasonRequest() async {
        let counter = FetchCounter()
        let provider = EpisodeArtworkProvider { _ in
            counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return [1: "/ep1.jpg", 2: "/ep2.jpg"]
        }
        async let first = provider.stillURL(seriesID: 100, seasonNumber: 4, episodeNumber: 1)
        async let second = provider.stillURL(seriesID: 100, seasonNumber: 4, episodeNumber: 2)
        let (url1, url2) = await (first, second)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(url1?.absoluteString, "https://image.tmdb.org/t/p/w780/ep1.jpg")
        XCTAssertEqual(url2?.absoluteString, "https://image.tmdb.org/t/p/w780/ep2.jpg")
    }

    func testDifferentSeriesOrSeasonNeverReusesMapping() async {
        let counter = FetchCounter()
        let provider = EpisodeArtworkProvider { key in
            counter.increment()
            // Every season map uses a still path derived from its key so a
            // wrongly reused mapping is visible in the assertion.
            return [2: "/s\(key.seriesID)-\(key.seasonNumber).jpg"]
        }
        let a = await provider.stillURL(seriesID: 100, seasonNumber: 4, episodeNumber: 2)
        let b = await provider.stillURL(seriesID: 200, seasonNumber: 4, episodeNumber: 2)
        let c = await provider.stillURL(seriesID: 100, seasonNumber: 1, episodeNumber: 2)
        XCTAssertEqual(counter.value, 3)
        XCTAssertEqual(a?.absoluteString, "https://image.tmdb.org/t/p/w780/s100-4.jpg")
        XCTAssertEqual(b?.absoluteString, "https://image.tmdb.org/t/p/w780/s200-4.jpg")
        XCTAssertEqual(c?.absoluteString, "https://image.tmdb.org/t/p/w780/s100-1.jpg")
    }

    func testFailedSeasonFetchIsNotCached() async {
        let counter = FetchCounter()
        let provider = EpisodeArtworkProvider { _ in
            counter.increment()
            if counter.value == 1 { throw TMDBError.rejected(503) }
            return [1: "/ep1.jpg"]
        }
        let failed = await provider.stillURL(seriesID: 100, seasonNumber: 4, episodeNumber: 1)
        XCTAssertNil(failed)
        let retried = await provider.stillURL(seriesID: 100, seasonNumber: 4, episodeNumber: 1)
        XCTAssertEqual(counter.value, 2, "A failed fetch must be retried, not cached")
        XCTAssertEqual(retried?.absoluteString, "https://image.tmdb.org/t/p/w780/ep1.jpg")
    }

    // MARK: - Image URL convention

    func testImageURLUsesTMDBHostConvention() {
        XCTAssertEqual(EpisodeArtworkProvider.imageURL(stillPath: "/abc.jpg")?.absoluteString,
                       "https://image.tmdb.org/t/p/w780/abc.jpg")
        XCTAssertNil(EpisodeArtworkProvider.imageURL(stillPath: ""))
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
