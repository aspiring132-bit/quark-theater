import Foundation
import XCTest
@testable import QuarkTheater

final class HistoryRepositoryTests: XCTestCase {
    @MainActor
    func testSameFileIDKeepsSeparateProgressForEachAccount() throws {
        let repository = try HistoryRepository(url: databaseURL())
        try repository.save(record(account: "account-a", file: "shared-file", position: 12))
        try repository.save(record(account: "account-b", file: "shared-file", position: 74))

        XCTAssertEqual(try repository.history(accountID: "account-a", fileID: "shared-file")?.positionSeconds, 12)
        XCTAssertEqual(try repository.history(accountID: "account-b", fileID: "shared-file")?.positionSeconds, 74)
        XCTAssertEqual(try repository.recent(accountID: "account-a").count, 1)
        XCTAssertNil(try repository.history(accountID: "account-c", fileID: "shared-file"))
    }

    @MainActor
    func testHistorySurvivesClosingAndReopeningDatabase() throws {
        let url = try databaseURL()
        let expected = record(account: "account-a", file: "film", position: 37.5)
        var repository: HistoryRepository? = try HistoryRepository(url: url)
        try repository?.save(expected)
        repository = nil

        let reopened = try HistoryRepository(url: url)
        XCTAssertEqual(try reopened.history(accountID: "account-a", fileID: "film"), expected)
    }

    @MainActor
    func testSavingExistingKeyUpdatesOneRowIncludingCompletion() throws {
        let repository = try HistoryRepository(url: databaseURL())
        try repository.save(record(account: "account-a", file: "film", position: 12))
        var finished = record(account: "account-a", file: "film", position: 100)
        finished.completed = true
        finished.lastWatchedAt = Date(timeIntervalSince1970: 2_000)
        try repository.save(finished)

        XCTAssertEqual(try repository.recent(accountID: "account-a"), [finished])
    }

    @MainActor
    func testDeleteOnlyRemovesSpecifiedFileAndAccount() throws {
        let repository = try HistoryRepository(url: databaseURL())
        try repository.save(record(account: "account-a", file: "shared-file", position: 12))
        try repository.save(record(account: "account-a", file: "other-file", position: 22))
        try repository.save(record(account: "account-b", file: "shared-file", position: 74))
        try repository.delete(accountID: "account-a", fileID: "shared-file")

        XCTAssertNil(try repository.history(accountID: "account-a", fileID: "shared-file"))
        XCTAssertEqual(try repository.history(accountID: "account-a", fileID: "other-file")?.positionSeconds, 22)
        XCTAssertEqual(try repository.history(accountID: "account-b", fileID: "shared-file")?.positionSeconds, 74)
        // Deleting a missing row is idempotent.
        XCTAssertNoThrow(try repository.delete(accountID: "account-a", fileID: "shared-file"))
    }

    @MainActor
    func testClearOnlyRemovesSpecifiedAccount() throws {
        let repository = try HistoryRepository(url: databaseURL())
        try repository.save(record(account: "account-a", file: "first", position: 12))
        try repository.save(record(account: "account-a", file: "second", position: 22))
        let otherAccount = record(account: "account-b", file: "first", position: 74)
        try repository.save(otherAccount)
        try repository.clear(accountID: "account-a")

        XCTAssertTrue(try repository.recent(accountID: "account-a").isEmpty)
        XCTAssertEqual(try repository.recent(accountID: "account-b"), [otherAccount])
    }

    @MainActor
    func testRecentSortsNewestFirstAndUsesStableFileTieBreak() throws {
        let repository = try HistoryRepository(url: databaseURL())
        var oldest = record(account: "account-a", file: "old", position: 12)
        oldest.lastWatchedAt = Date(timeIntervalSince1970: 100)
        var newest = record(account: "account-a", file: "z", position: 22)
        newest.lastWatchedAt = Date(timeIntervalSince1970: 200)
        var tied = record(account: "account-a", file: "a", position: 33)
        tied.lastWatchedAt = newest.lastWatchedAt
        try repository.save(newest)
        try repository.save(oldest)
        try repository.save(tied)

        XCTAssertEqual(try repository.recent(accountID: "account-a").map(\.fileId), ["a", "z", "old"])
    }

    @MainActor
    func testRejectsInvalidProgressWithoutReplacingValidHistory() throws {
        let repository = try HistoryRepository(url: databaseURL())
        let valid = record(account: "account-a", file: "film", position: 12)
        try repository.save(valid)
        let invalidPairs: [(Double, Double)] = [
            (-1, 100), (.nan, 100), (.infinity, 100), (-.infinity, 100),
            (12, -1), (12, .nan), (12, .infinity), (101, 100)
        ]
        for (position, duration) in invalidPairs {
            var invalid = valid
            invalid.positionSeconds = position
            invalid.durationSeconds = duration
            XCTAssertThrowsError(try repository.save(invalid)) { error in
                XCTAssertEqual(error as? HistoryRepositoryError, .invalidProgress)
            }
        }
        XCTAssertEqual(try repository.history(accountID: "account-a", fileID: "film"), valid)
    }

    @MainActor
    func testZeroDurationRepresentsUnknownDuration() throws {
        let repository = try HistoryRepository(url: databaseURL())
        var unknownDuration = record(account: "account-a", file: "film", position: 42)
        unknownDuration.durationSeconds = 0
        try repository.save(unknownDuration)

        XCTAssertEqual(try repository.history(accountID: "account-a", fileID: "film"), unknownDuration)
    }

    @MainActor
    func testIdentifiersAreBoundAsDataAndPreserveUnicode() throws {
        let repository = try HistoryRepository(url: databaseURL())
        let account = "账号'; DELETE FROM watch_history; --"
        let file = "影片\" / α"
        let expected = record(account: account, file: file, position: 12)
        let control = record(account: "account-b", file: "keep", position: 22)
        try repository.save(expected)
        try repository.save(control)

        XCTAssertEqual(try repository.history(accountID: account, fileID: file), expected)
        try repository.clear(accountID: account)
        XCTAssertEqual(try repository.recent(accountID: "account-b"), [control])
    }

    @MainActor
    func testRejectsEmptyAndNullContainingIdentifiers() throws {
        let repository = try HistoryRepository(url: databaseURL())
        for identifier in ["", "   ", "abc\0def"] {
            XCTAssertThrowsError(try repository.save(record(account: identifier, file: "film", position: 12)))
            XCTAssertThrowsError(try repository.history(accountID: "account-a", fileID: identifier))
        }
        XCTAssertTrue(try repository.recent(accountID: "account-a").isEmpty)
    }

    @MainActor
    func testRecreatesDatabaseAfterCacheWasPurged() throws {
        let url = try databaseURL()
        var repository: HistoryRepository? = try HistoryRepository(url: url)
        try repository?.save(record(account: "account-a", file: "film", position: 12))
        repository = nil
        try FileManager.default.removeItem(at: url)
        let recreated = try HistoryRepository(url: url)

        // A cache purge is recoverable, but the purged viewing history is lost.
        XCTAssertTrue(try recreated.recent(accountID: "account-a").isEmpty)
        XCTAssertNoThrow(try recreated.save(record(account: "account-a", file: "new", position: 1)))
    }

    private func record(account: String, file: String, position: Double) -> WatchHistory {
        WatchHistory(
            accountId: account,
            fileId: file,
            positionSeconds: position,
            durationSeconds: 100,
            lastWatchedAt: Date(timeIntervalSince1970: 1_000),
            completed: false
        )
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarkTheaterHistoryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("history.sqlite")
    }
}
