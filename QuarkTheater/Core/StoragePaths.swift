import Foundation

enum StoragePaths {
    private static let subfolder = "QuarkTheater"

    /// Application Support 仅在**可写**时返回。tvOS 真机上该目录只读
    /// （2026-10-18 真机卡死根因：`createDirectory` 抛"没有保存到 Application Support 的权限"），
    /// 此时返回 nil，调用方自动回退到 Caches。
    static var appSupportDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(subfolder, isDirectory: true)
        return makeWritableDirectory(dir) ? dir : nil
    }

    static var cachesDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent(subfolder, isDirectory: true)
        return makeWritableDirectory(dir) ? dir : nil
    }

    /// 诊断日志目录：优先 Application Support，真机上不可写则回退 Caches。
    static var diagnosticsDirectory: URL? {
        let parent = appSupportDirectory ?? cachesDirectory ?? FileManager.default.temporaryDirectory
        let dir = parent.appendingPathComponent("Diagnostics", isDirectory: true)
        return makeWritableDirectory(dir) ? dir : nil
    }

    /// 日志导出目录：tvOS 真机上 documentDirectory 可能只读，回退 Caches。
    static var exportDirectory: URL {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           makeWritableDirectory(docs) {
            return docs
        }
        return cachesDirectory ?? FileManager.default.temporaryDirectory
    }

    /// Durable database URL for watch history in Application Support, migrating from Caches if needed.
    /// 真机上 Application Support 不可写时自动落到 Caches。
    static func watchHistoryDatabaseURL() -> URL? {
        databaseURL(filename: "watch-history.sqlite")
    }

    /// Durable database URL for media catalog in Application Support, migrating from Caches if needed.
    static func mediaCatalogDatabaseURL() -> URL? {
        databaseURL(filename: "media-catalog.sqlite")
    }

    private static func databaseURL(filename: String) -> URL? {
        guard let appSupportDir = appSupportDirectory else {
            // Fallback to caches if application support is unavailable or read-only
            return cachesDirectory?.appendingPathComponent(filename)
        }
        let targetURL = appSupportDir.appendingPathComponent(filename)

        // Migrate legacy database from Caches if target doesn't exist yet
        if !FileManager.default.fileExists(atPath: targetURL.path),
           let cacheDir = cachesDirectory {
            let legacyURL = cacheDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.copyItem(at: legacyURL, to: targetURL)
            }
        }

        return targetURL
    }

    /// 创建目录并在成功时返回 true。tvOS 真机上 Application Support 只读，
    /// `createDirectory` 会抛权限错误，此时返回 false 触发调用方回退。
    private static func makeWritableDirectory(_ dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
