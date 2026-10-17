import Foundation
import SQLite3

enum MediaCatalogError: Error, LocalizedError {
    case invalidMatch, database(Int32), corruptRecord
    var errorDescription: String? {
        switch self {
        case .invalidMatch: return "影视匹配缺少账号、文件或 TMDB 标识。"
        case .database(let code): return "影视目录写入失败（SQLite \(code)）。"
        case .corruptRecord: return "影视目录存在无法读取的数据。"
        }
    }
}

struct MediaScanDiff: Equatable {
    let added: Int
    let changed: Int
    let removed: Int
}

/// Stores only explicitly confirmed metadata, separated by account and cloud file.
@MainActor
final class MediaCatalogRepository {
    // nonisolated(unsafe): written only from init (before other references exist)
    // and read only from deinit (after all references drop). All other accesses
    // are on the main actor. Safe, but opted out of Swift 6 actor isolation checking.
    nonisolated(unsafe) private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard url.isFileURL else { throw MediaCatalogError.database(SQLITE_MISUSE) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw MediaCatalogError.database(result)
        }
        database = opened
        let schema = """
        CREATE TABLE IF NOT EXISTS media_catalog (
          account_id TEXT NOT NULL, file_id TEXT NOT NULL, payload BLOB NOT NULL,
          PRIMARY KEY(account_id, file_id));
        CREATE TABLE IF NOT EXISTS media_favorites (
          account_id TEXT NOT NULL, file_id TEXT NOT NULL,
          PRIMARY KEY(account_id, file_id));
        CREATE TABLE IF NOT EXISTS media_scan (
          account_id TEXT NOT NULL, file_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
          PRIMARY KEY(account_id, file_id));
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(opened)
            sqlite3_close_v2(opened); database = nil
            throw MediaCatalogError.database(code)
        }
    }

    deinit { if let database { sqlite3_close_v2(database) } }

    func confirm(_ item: MediaItem, accountID: String) throws {
        guard !accountID.isEmpty, !item.fileId.isEmpty, let tmdbID = item.tmdbId, tmdbID > 0,
              let confidence = item.matchConfidence, confidence.isFinite, (0...1).contains(confidence) else {
            throw MediaCatalogError.invalidMatch
        }
        let data = try JSONEncoder().encode(item)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO media_catalog(account_id,file_id,payload) VALUES(?,?,?) ON CONFLICT(account_id,file_id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1)
        bind(item.fileId, statement, 2)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw MediaCatalogError.database(result) }
    }

    func confirmed(accountID: String) throws -> [MediaItem] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM media_catalog WHERE account_id=? ORDER BY file_id", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1)
        var items: [MediaItem] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return items }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw MediaCatalogError.corruptRecord }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            guard let item = try? JSONDecoder().decode(MediaItem.self, from: data) else { throw MediaCatalogError.corruptRecord }
            items.append(item)
        }
    }

    func remove(accountID: String, fileID: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM media_catalog WHERE account_id=? AND file_id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1); bind(fileID, statement, 2)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw MediaCatalogError.database(code) }
        try setFavorite(accountID: accountID, fileID: fileID, favorite: false)
    }

    func favoriteFileIDs(accountID: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT file_id FROM media_favorites WHERE account_id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1)
        var ids = Set<String>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return ids }
            guard code == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw MediaCatalogError.corruptRecord }
            ids.insert(String(cString: value))
        }
    }

    func setFavorite(accountID: String, fileID: String, favorite: Bool) throws {
        var statement: OpaquePointer?
        let sql = favorite
            ? "INSERT OR IGNORE INTO media_favorites(account_id,file_id) VALUES(?,?)"
            : "DELETE FROM media_favorites WHERE account_id=? AND file_id=?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1); bind(fileID, statement, 2)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw MediaCatalogError.database(code) }
    }

    func reconcileScan(accountID: String, candidates: [ScannedMediaCandidate]) throws -> MediaScanDiff {
        guard !accountID.isEmpty else { throw MediaCatalogError.invalidMatch }
        let candidateIDs = candidates.map(\.file.fileId)
        guard candidateIDs.allSatisfy({ !$0.isEmpty }), Set(candidateIDs).count == candidateIDs.count else {
            throw MediaCatalogError.invalidMatch
        }
        var old: [String: String] = [:]
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT file_id,fingerprint FROM media_scan WHERE account_id=?", -1, &select, nil) == SQLITE_OK,
              let select else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        bind(accountID, select, 1)
        while true {
            let code = sqlite3_step(select)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW,
                  let fileID = sqlite3_column_text(select, 0),
                  let fingerprint = sqlite3_column_text(select, 1) else {
                sqlite3_finalize(select)
                throw MediaCatalogError.corruptRecord
            }
            old[String(cString: fileID)] = String(cString: fingerprint)
        }
        sqlite3_finalize(select)

        let current = Dictionary(uniqueKeysWithValues: candidates.map { ($0.file.fileId, fingerprint($0.file)) })
        var added = 0, changed = 0
        var changedIDs = [String]()
        for (fileID, value) in current {
            if let previous = old[fileID] {
                if previous != value { changed += 1; changedIDs.append(fileID) }
            } else { added += 1 }
        }
        let removedIDs = Set(old.keys).subtracting(current.keys)
        try execute("BEGIN IMMEDIATE;")
        do {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM media_scan WHERE account_id=?", -1, &delete, nil) == SQLITE_OK,
                  let delete else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
            bind(accountID, delete, 1)
            let deleteCode = sqlite3_step(delete); sqlite3_finalize(delete)
            guard deleteCode == SQLITE_DONE else { throw MediaCatalogError.database(deleteCode) }
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO media_scan(account_id,file_id,fingerprint) VALUES(?,?,?)", -1, &insert, nil) == SQLITE_OK,
                  let insert else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
            for (fileID, value) in current {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(accountID, insert, 1); bind(fileID, insert, 2); bind(value, insert, 3)
                let code = sqlite3_step(insert)
                guard code == SQLITE_DONE else { sqlite3_finalize(insert); throw MediaCatalogError.database(code) }
            }
            sqlite3_finalize(insert)
            for fileID in changedIDs { try deleteMetadata(accountID: accountID, fileID: fileID) }
            for fileID in removedIDs {
                try deleteMetadata(accountID: accountID, fileID: fileID)
                try deleteFavorite(accountID: accountID, fileID: fileID)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return MediaScanDiff(added: added, changed: changed, removed: removedIDs.count)
    }

    func clear(accountID: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM media_catalog WHERE account_id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw MediaCatalogError.database(code) }
        var favorites: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM media_favorites WHERE account_id=?", -1, &favorites, nil) == SQLITE_OK,
              let favorites else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(favorites) }
        bind(accountID, favorites, 1)
        let favoriteCode = sqlite3_step(favorites)
        guard favoriteCode == SQLITE_DONE else { throw MediaCatalogError.database(favoriteCode) }
        var scan: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM media_scan WHERE account_id=?", -1, &scan, nil) == SQLITE_OK,
              let scan else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(scan) }
        bind(accountID, scan, 1)
        let scanCode = sqlite3_step(scan)
        guard scanCode == SQLITE_DONE else { throw MediaCatalogError.database(scanCode) }
    }

    private func fingerprint(_ file: CloudFile) -> String {
        "\(file.parentId.utf8.count):\(file.parentId)|\(file.name.utf8.count):\(file.name)|\(file.size)|\(file.modifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func deleteMetadata(accountID: String, fileID: String) throws {
        try deleteRows("DELETE FROM media_catalog WHERE account_id=? AND file_id=?", accountID, fileID)
    }
    private func deleteFavorite(accountID: String, fileID: String) throws {
        try deleteRows("DELETE FROM media_favorites WHERE account_id=? AND file_id=?", accountID, fileID)
    }
    private func deleteRows(_ sql: String, _ accountID: String, _ fileID: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw MediaCatalogError.database(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        bind(accountID, statement, 1); bind(fileID, statement, 2)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw MediaCatalogError.database(code) }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MediaCatalogError.database(sqlite3_errcode(database))
        }
    }

    private func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
}
