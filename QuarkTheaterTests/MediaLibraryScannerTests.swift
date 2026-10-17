import XCTest
@testable import QuarkTheater

@MainActor
final class MediaLibraryScannerTests: XCTestCase {
    func testScansNestedDirectoriesAndIdentifiesVideoFiles() async throws {
        let client = MockQuarkClient()
        _ = client.enterDemo()
        var counts: [Int] = []
        let results = try await MediaLibraryScanner().scan(client: client) { counts.append($0) }
        XCTAssertEqual(Set(results.map(\.file.fileId)), ["mock-video", "mock-episode"])
        XCTAssertTrue(results.contains { $0.parsedName.seasonNumber == 1 && $0.parsedName.episodeNumber == 2 })
        XCTAssertFalse(counts.isEmpty)
    }
}
