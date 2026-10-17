import Foundation
import SQLite3

enum HistoryRepositoryError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case invalidProgress
    case invalidDate
    case invalidDatabaseURL
    case unsupportedSchema(Int)
    case database(operation: String, code: Int32)
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "观看记录缺少有效的账号或文件标识。"
        case .invalidProgress: return "观看进度必须为有限的非负秒数，且不能超过已知视频时长。"
        case .invalidDate: return "观看记录的时间无效。"
        case .invalidDatabaseURL: return "观看记录数据库必须使用本地文件地址。"
        case .unsupportedSchema(let version): return "观看记录数据库版本 \(version) 高于当前应用支持的版本。"
        case .database(let operation, let code): return "观看记录存储失败（\(operation)，SQLite \(code)）。"
        case .corruptRecord: return "观看记录数据库包含无效数据。"
        }
    }
}

/// Phase 0 infrastructure only; not yet connected to a player or history screen.
/// The caller supplies a tvOS caches-directory URL. tvOS may purge that directory
/// between launches; this repository recreates an absent database, but cannot
/// recover purged viewing history. Cross-device/durable backup is not implemented.
@MainActor
final class HistoryRepository {
    // nonisolated(unsafe): written only from init (before other references exist)
    // and read only from deinit (after all references drop). All other accesses
    // are on the main actor. Safe, but opted out of Swift 6 actor isolation checking.
    nonisolated(unsafe) private var database: OpaquePointer?
    private static let schemaVersion = 2
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard url.isFileURL else { throw HistoryRepositoryError.invalidDatabaseURL }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path, &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw HistoryRepositoryError.database(operation: "open", code: result)
        }
        database = opened
        do {
            try check(sqlite3_busy_timeout(database, 250), operation: "busy timeout")
            try migrate()
        } catch {
            // Clear the handle so a fully initialized throwing instance cannot close it twice.
            sqlite3_close_v2(database)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func save(_ history: WatchHistory) throws {
        try validate(history)
        let statement = try prepare("""
            INSERT INTO watch_history
                (account_id, file_id, file_name, position_seconds, duration_seconds, last_watched_at, completed)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, file_id) DO UPDATE SET
                file_name = coalesce(excluded.file_name, watch_history.file_name),
                position_seconds = excluded.position_seconds,
                duration_seconds = excluded.duration_seconds,
                last_watched_at = excluded.last_watched_at,
                completed = excluded.completed;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(history.accountId, to: statement, at: 1)
        try bind(history.fileId, to: statement, at: 2)
        if let name = history.fileName {
            try bind(name, to: statement, at: 3)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        try check(sqlite3_bind_double(statement, 4, history.positionSeconds), operation: "bind position")
        try check(sqlite3_bind_double(statement, 5, history.durationSeconds), operation: "bind duration")
        try check(sqlite3_bind_double(statement, 6, history.lastWatchedAt.timeIntervalSince1970), operation: "bind date")
        try check(sqlite3_bind_int(statement, 7, history.completed ? 1 : 0), operation: "bind completed")
        try finish(statement)
    }

    func history(accountID: String, fileID: String) throws -> WatchHistory? {
        try validateIdentifier(accountID)
        try validateIdentifier(fileID)
        let statement = try prepare("""
            SELECT account_id, file_id, position_seconds, duration_seconds, last_watched_at, completed, file_name
            FROM watch_history WHERE account_id = ? AND file_id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: statement, at: 1)
        try bind(fileID, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw HistoryRepositoryError.database(operation: "read history", code: result)
        }
        return try read(statement)
    }

    func recent(accountID: String) throws -> [WatchHistory] {
        try validateIdentifier(accountID)
        let statement = try prepare("""
            SELECT account_id, file_id, position_seconds, duration_seconds, last_watched_at, completed, file_name
            FROM watch_history WHERE account_id = ?
            ORDER BY last_watched_at DESC, file_id ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: statement, at: 1)
        var records: [WatchHistory] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW else {
                throw HistoryRepositoryError.database(operation: "read recent", code: result)
            }
            records.append(try read(statement))
        }
    }

    func delete(accountID: String, fileID: String) throws {
        try validateIdentifier(accountID)
        try validateIdentifier(fileID)
        let statement = try prepare("DELETE FROM watch_history WHERE account_id = ? AND file_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: statement, at: 1)
        try bind(fileID, to: statement, at: 2)
        try finish(statement)
    }

    func clear(accountID: String) throws {
        try validateIdentifier(accountID)
        let statement = try prepare("DELETE FROM watch_history WHERE account_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: statement, at: 1)
        try finish(statement)
    }

    private func migrate() throws {
        let statement = try prepare("PRAGMA user_version;")
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            sqlite3_finalize(statement)
            throw HistoryRepositoryError.database(operation: "schema version", code: result)
        }
        let version = Int(sqlite3_column_int(statement, 0))
        sqlite3_finalize(statement)
        guard version <= Self.schemaVersion else {
            throw HistoryRepositoryError.unsupportedSchema(version)
        }
        if version == 0 {
            try execute("BEGIN IMMEDIATE;")
            do {
                try execute("""
                    CREATE TABLE IF NOT EXISTS watch_history (
                        account_id TEXT NOT NULL CHECK(length(account_id) > 0),
                        file_id TEXT NOT NULL CHECK(length(file_id) > 0),
                        file_name TEXT,
                        position_seconds REAL NOT NULL CHECK(position_seconds >= 0),
                        duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0),
                        last_watched_at REAL NOT NULL,
                        completed INTEGER NOT NULL CHECK(completed IN (0, 1)),
                        PRIMARY KEY(account_id, file_id),
                        CHECK(duration_seconds = 0 OR position_seconds <= duration_seconds)
                    );
                    CREATE INDEX IF NOT EXISTS watch_history_recent
                        ON watch_history(account_id, last_watched_at DESC);
                    PRAGMA user_version = 2;
                    """)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } else if version == 1 {
            try execute("BEGIN IMMEDIATE;")
            do {
                try execute("""
                    ALTER TABLE watch_history ADD COLUMN file_name TEXT;
                    PRAGMA user_version = 2;
                    """)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func validateIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.utf8.contains(0) else {
            throw HistoryRepositoryError.invalidIdentifier
        }
    }

    private func validate(_ history: WatchHistory) throws {
        try validateIdentifier(history.accountId)
        try validateIdentifier(history.fileId)
        guard history.positionSeconds.isFinite, history.durationSeconds.isFinite,
              history.positionSeconds >= 0, history.durationSeconds >= 0,
              history.durationSeconds == 0 || history.positionSeconds <= history.durationSeconds else {
            throw HistoryRepositoryError.invalidProgress
        }
        guard history.lastWatchedAt.timeIntervalSince1970.isFinite else {
            throw HistoryRepositoryError.invalidDate
        }
    }

    private func read(_ statement: OpaquePointer) throws -> WatchHistory {
        guard let account = sqlite3_column_text(statement, 0),
              let file = sqlite3_column_text(statement, 1),
              sqlite3_column_type(statement, 2) != SQLITE_NULL,
              sqlite3_column_type(statement, 3) != SQLITE_NULL,
              sqlite3_column_type(statement, 4) != SQLITE_NULL else {
            throw HistoryRepositoryError.corruptRecord
        }
        let completed = sqlite3_column_int(statement, 5)
        guard completed == 0 || completed == 1 else { throw HistoryRepositoryError.corruptRecord }
        let fileName: String? = sqlite3_column_text(statement, 6).map { String(cString: $0) }
        let record = WatchHistory(
            accountId: String(cString: account),
            fileId: String(cString: file),
            fileName: fileName,
            positionSeconds: sqlite3_column_double(statement, 2),
            durationSeconds: sqlite3_column_double(statement, 3),
            lastWatchedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            completed: completed == 1
        )
        do { try validate(record) } catch { throw HistoryRepositoryError.corruptRecord }
        return record
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw HistoryRepositoryError.database(operation: "prepare", code: result)
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        // SQLITE_TRANSIENT copies the temporary Swift C string before it expires.
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        try check(result, operation: "bind identifier")
    }

    private func finish(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw HistoryRepositoryError.database(operation: "write history", code: result)
        }
    }

    private func execute(_ sql: String) throws {
        // Only fixed schema/transaction SQL is passed here; all user values are bound.
        try check(sqlite3_exec(database, sql, nil, nil, nil), operation: "schema")
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else {
            // Avoid returning SQLite error strings, which can expose values or paths.
            throw HistoryRepositoryError.database(operation: operation, code: result)
        }
    }
}
