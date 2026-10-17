import Foundation

enum AuthenticationState: String, Codable {
    case signedOut, authenticated, expired
}

struct Account: Codable, Equatable, Identifiable {
    let accountId: String
    var displayName: String
    var authenticationState: AuthenticationState
    var id: String { accountId }
}

struct CloudFile: Codable, Equatable, Identifiable {
    let fileId: String
    let parentId: String
    let name: String
    let size: Int64
    let fileExtension: String
    let modifiedAt: Date?
    let isDirectory: Bool
    var id: String { fileId }
    var isVideo: Bool {
        !isDirectory && ["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "webm"].contains(fileExtension.lowercased())
    }
}

struct CloudFilePage: Equatable {
    let files: [CloudFile]
    let page: Int
    let pageSize: Int
    let total: Int?
    var hasMore: Bool {
        if files.isEmpty { return false }
        if let total { return page * pageSize < total }
        return files.count == pageSize
    }
}

enum MediaType: String, Codable { case movie, series, unknown }

// Phase 2 schema only. No unconfirmed TMDB match is written by Phase 0.
struct MediaItem: Codable, Identifiable {
    let id: String
    let fileId: String
    var mediaType: MediaType
    var title: String
    var year: Int?
    var tmdbId: Int?
    var posterPath: String?
    var backdropPath: String?
    var overview: String?
    var duration: TimeInterval?
    var matchConfidence: Double?
    var rating: Double? = nil
    var genreIDs: [Int]? = nil
}

struct Episode: Codable, Identifiable {
    let id: String
    let mediaId: String
    let fileId: String
    let seasonNumber: Int
    let episodeNumber: Int
    var title: String
}

struct WatchHistory: Codable, Equatable, Identifiable {
    let accountId: String
    let fileId: String
    var fileName: String? = nil
    var positionSeconds: Double
    var durationSeconds: Double
    var lastWatchedAt: Date
    var completed: Bool
    // Length-delimited composition avoids ambiguities in arbitrary server identifiers.
    var id: String { "\(accountId.count):\(accountId)\(fileId)" }
    var displayName: String {
        if let fileName, !fileName.isEmpty { return fileName }
        return fileId
    }
}

// Ephemeral only: never write signed URLs/cookies into SQLite, preferences or logs.
struct PlaybackSession {
    let fileId: String
    var playbackURL: URL
    var expiresAt: Date?
    var lastPosition: Double
    var retryCount: Int
}

struct QRLoginChallenge {
    let token: String
    let qrURL: URL
    let createdAt: Date
}

enum QRLoginState {
    case waiting
    case authenticated(Account)
    case expired
}

struct PlaybackResource {
    let fileID: String
    let url: URL
    let cookies: [HTTPCookie]
    let requiredHTTPHeaders: [String: String]
    let expiresAt: Date?
}
