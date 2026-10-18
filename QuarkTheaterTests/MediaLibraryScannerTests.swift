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

    func testNamedBoundRootAndSeasonFolderProvideContextForBareEpisode() async throws {
        let client = ContextMockQuarkClient()
        let results = try await MediaLibraryScanner().scan(
            client: client,
            roots: [MediaScanRoot(id: "root", name: "权力的游戏")]
        )

        let parsed = try XCTUnwrap(results.first?.parsedName)
        XCTAssertEqual(parsed.title, "权力的游戏")
        XCTAssertEqual(parsed.mediaType, .series)
        XCTAssertEqual(parsed.seasonNumber, 1)
        XCTAssertEqual(parsed.episodeNumber, 1)
        XCTAssertEqual(results.first?.pathComponents, ["权力的游戏", "S01"])
    }

    func testNearestShowFolderWinsWhenBoundRootIsCategory() async throws {
        let client = CategoryMockQuarkClient()
        let results = try await MediaLibraryScanner().scan(
            client: client,
            roots: [MediaScanRoot(id: "root", name: "合集根目录")]
        )
        XCTAssertEqual(results.first?.parsedName.title, "真正的剧名")
        XCTAssertEqual(results.first?.parsedName.seasonNumber, 1)
        XCTAssertEqual(results.first?.parsedName.episodeNumber, 1)
    }

    func testLegacyCandidateInitializerRetainsDefaultPathComponents() {
        let file = CloudFile(
            fileId: "episode",
            parentId: "season",
            name: "01.mp4",
            size: 1,
            fileExtension: "mp4",
            modifiedAt: nil,
            isDirectory: false
        )
        let parsed = ParsedMediaName(title: "权力的游戏", mediaType: .series, seasonNumber: 1, episodeNumber: 1)

        let candidate = ScannedMediaCandidate(file: file, parsedName: parsed)

        XCTAssertEqual(candidate.pathComponents, [])
    }
}

@MainActor
private class ContextMockQuarkClient: QuarkClient {
    func restoreSession() async throws -> Account? { nil }
    func beginQRCodeLogin() async throws -> QRLoginChallenge { throw QuarkError.mockOnly }
    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { throw QuarkError.mockOnly }
    func cancelQRCodeLogin() {}
    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        let files: [CloudFile]
        switch parentID {
        case "root":
            files = [CloudFile(fileId: "season", parentId: "root", name: "S01", size: 0, fileExtension: "", modifiedAt: nil, isDirectory: true)]
        case "season":
            files = [CloudFile(fileId: "episode", parentId: "season", name: "01.mp4", size: 1, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)]
        default:
            files = []
        }
        return CloudFilePage(files: files, page: page, pageSize: pageSize, total: files.count)
    }
    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage { throw QuarkError.mockOnly }
    func playbackResource(fileID: String) async throws -> PlaybackResource { throw QuarkError.mockOnly }
    func logout() async throws {}
}

@MainActor
private final class CategoryMockQuarkClient: ContextMockQuarkClient {
    override func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        let files: [CloudFile]
        switch parentID {
        case "root": files = [CloudFile(fileId: "category", parentId: "root", name: "剧集分类", size: 0, fileExtension: "", modifiedAt: nil, isDirectory: true)]
        case "category": files = [CloudFile(fileId: "show", parentId: "category", name: "真正的剧名", size: 0, fileExtension: "", modifiedAt: nil, isDirectory: true)]
        case "show": files = [CloudFile(fileId: "season", parentId: "show", name: "S01", size: 0, fileExtension: "", modifiedAt: nil, isDirectory: true)]
        case "season": files = [CloudFile(fileId: "episode", parentId: "season", name: "01.mp4", size: 1, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)]
        default: files = []
        }
        return CloudFilePage(files: files, page: page, pageSize: pageSize, total: files.count)
    }
}
