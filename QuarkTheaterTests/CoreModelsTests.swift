import XCTest
@testable import QuarkTheater

final class CoreModelsTests: XCTestCase {
    private func file(_ id: String, ext: String = "mp4", directory: Bool = false) -> CloudFile {
        CloudFile(fileId: id, parentId: "0", name: id, size: 0,
                  fileExtension: ext, modifiedAt: nil, isDirectory: directory)
    }

    func testPaginationUsesReportedTotalAcrossPartialLastPage() {
        let first = CloudFilePage(files: [file("1"), file("2")], page: 1, pageSize: 2, total: 3)
        let last = CloudFilePage(files: [file("3")], page: 2, pageSize: 2, total: 3)
        XCTAssertTrue(first.hasMore)
        XCTAssertFalse(last.hasMore)
    }

    func testPaginationWithoutTotalRequiresFullPage() {
        XCTAssertTrue(CloudFilePage(files: [file("1"), file("2")], page: 1, pageSize: 2, total: nil).hasMore)
        XCTAssertFalse(CloudFilePage(files: [file("3")], page: 2, pageSize: 2, total: nil).hasMore)
    }

    func testEmptyPageStopsEvenIfServerTotalIsStale() {
        XCTAssertFalse(CloudFilePage(files: [], page: 2, pageSize: 50, total: 500).hasMore)
    }

    func testVideoExtensionIsCaseInsensitiveAndExcludesDirectories() {
        XCTAssertTrue(file("movie", ext: "MKV").isVideo)
        XCTAssertFalse(file("folder", ext: "mp4", directory: true).isVideo)
        XCTAssertFalse(file("readme", ext: "txt").isVideo)
    }

    func testHistoryIdentityIncludesAccountAndFileWithoutConcatenationCollisions() {
        func history(_ account: String, _ file: String) -> WatchHistory {
            WatchHistory(accountId: account, fileId: file, positionSeconds: 10,
                         durationSeconds: 100, lastWatchedAt: Date(timeIntervalSince1970: 0), completed: false)
        }
        XCTAssertNotEqual(history("account-a", "same-file").id, history("account-b", "same-file").id)
        XCTAssertNotEqual(history("ab", "c").id, history("a", "bc").id)
        XCTAssertEqual(history("account-a", "same-file").id, history("account-a", "same-file").id)
    }

    func testAccountCodablePreservesAuthenticationState() throws {
        let account = Account(accountId: "fixture-account", displayName: "测试账号", authenticationState: .expired)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account)), account)
    }
}
