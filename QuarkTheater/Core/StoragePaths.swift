import Foundation

enum StoragePaths {
    private static let subfolder = "QuarkTheater"

    static var appSupportDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(subfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cachesDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent(subfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Durable database URL for watch history in Application Support, migrating from Caches if needed.
    static func watchHistoryDatabaseURL() -> URL? {
        databaseURL(filename: "watch-history.sqlite")
    }

    /// Durable database URL for media catalog in Application Support, migrating from Caches if needed.
    static func mediaCatalogDatabaseURL() -> URL? {
        databaseURL(filename: "media-catalog.sqlite")
    }

    private static func databaseURL(filename: String) -> URL? {
        guard let appSupportDir = appSupportDirectory else {
            // Fallback to caches if application support is unavailable
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
}
