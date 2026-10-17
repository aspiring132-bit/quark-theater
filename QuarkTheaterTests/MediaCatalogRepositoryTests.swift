import XCTest
@testable import QuarkTheater

@MainActor
final class MediaCatalogRepositoryTests: XCTestCase {
    private func repository() throws -> (MediaCatalogRepository, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("catalog.sqlite")
        return (try MediaCatalogRepository(url: url), folder)
    }
    func testConfirmedMetadataPersistsAndSeparatesAccounts() throws {
        let (repo, folder) = try repository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = MediaItem(id: "f-1", fileId: "f-1", mediaType: .movie, title: "Dune", year: 2021,
            tmdbId: 438631, posterPath: "/poster.jpg", backdropPath: nil, overview: nil,
            duration: nil, matchConfidence: 0.98)
        try repo.confirm(item, accountID: "account-a")
        XCTAssertEqual(try repo.confirmed(accountID: "account-a").first?.tmdbId, 438631)
        XCTAssertTrue(try repo.confirmed(accountID: "account-b").isEmpty)
    }
    func testUnresolvedCandidateCannotBePersisted() throws {
        let (repo, folder) = try repository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = MediaItem(id: "f-1", fileId: "f-1", mediaType: .movie, title: "Maybe", year: nil,
            tmdbId: nil, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: nil)
        XCTAssertThrowsError(try repo.confirm(item, accountID: "account-a"))
    }
    func testFavoritesAreAccountScoped() throws {
        let (repo, folder) = try repository()
        defer { try? FileManager.default.removeItem(at: folder) }
        try repo.setFavorite(accountID: "account-a", fileID: "f-1", favorite: true)
        XCTAssertEqual(try repo.favoriteFileIDs(accountID: "account-a"), ["f-1"])
        XCTAssertTrue(try repo.favoriteFileIDs(accountID: "account-b").isEmpty)
        try repo.setFavorite(accountID: "account-a", fileID: "f-1", favorite: false)
        XCTAssertTrue(try repo.favoriteFileIDs(accountID: "account-a").isEmpty)
    }
    func testScanDiffTracksAddsChangesAndDeletesWithinAccount() throws {
        let (repo, folder) = try repository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CloudFile(fileId: "video-1", parentId: "folder-1", name: "Dune.2021.mp4",
            size: 100, fileExtension: "mp4", modifiedAt: Date(timeIntervalSince1970: 10), isDirectory: false)
        let candidate = ScannedMediaCandidate(file: file,
            parsedName: ParsedMediaName(title: "Dune", year: 2021, mediaType: .movie, seasonNumber: nil, episodeNumber: nil))
        XCTAssertEqual(try repo.reconcileScan(accountID: "account-a", candidates: [candidate]),
                       MediaScanDiff(added: 1, changed: 0, removed: 0))
        XCTAssertEqual(try repo.reconcileScan(accountID: "account-a", candidates: [candidate]),
                       MediaScanDiff(added: 0, changed: 0, removed: 0))
        let matched = MediaItem(id: "video-1", fileId: "video-1", mediaType: .movie, title: "Dune", year: 2021,
            tmdbId: 438631, posterPath: nil, backdropPath: nil, overview: nil, duration: nil, matchConfidence: 0.98)
        try repo.confirm(matched, accountID: "account-a")
        let updatedFile = CloudFile(fileId: "video-1", parentId: "folder-1", name: "Dune.2021.mp4",
            size: 200, fileExtension: "mp4", modifiedAt: Date(timeIntervalSince1970: 10), isDirectory: false)
        let updated = ScannedMediaCandidate(file: updatedFile, parsedName: candidate.parsedName)
        XCTAssertEqual(try repo.reconcileScan(accountID: "account-a", candidates: [updated]),
                       MediaScanDiff(added: 0, changed: 1, removed: 0))
        XCTAssertTrue(try repo.confirmed(accountID: "account-a").isEmpty)
        XCTAssertEqual(try repo.reconcileScan(accountID: "account-a", candidates: []),
                       MediaScanDiff(added: 0, changed: 0, removed: 1))
        XCTAssertEqual(try repo.reconcileScan(accountID: "account-b", candidates: [candidate]).added, 1)
    }
}
