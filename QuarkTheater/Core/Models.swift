import Foundation
import SwiftUI

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

enum StorageSourceType: String, Codable, CaseIterable {
    case quark = "quark"
    case aliyun = "aliyun"
    case webdav = "webdav"
    case smb = "smb"

    var displayName: String {
        switch self {
        case .quark: return "夸克"
        case .aliyun: return "阿里"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        }
    }

    var iconName: String {
        switch self {
        case .quark: return "cloud.fill"
        case .aliyun: return "externaldrive.fill.badge.icloud"
        case .webdav: return "network"
        case .smb: return "server.rack"
        }
    }
}

struct SourceBadgeView: View {
    let type: StorageSourceType
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.iconName)
                .font(.system(size: 11))
            Text(type.displayName)
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
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
    var sourceType: StorageSourceType = .quark

    enum CodingKeys: String, CodingKey {
        case id, fileId, mediaType, title, year, tmdbId
        case posterPath, backdropPath, overview, duration
        case matchConfidence, rating, genreIDs, sourceType
    }

    init(id: String, fileId: String, mediaType: MediaType, title: String,
         year: Int? = nil, tmdbId: Int? = nil, posterPath: String? = nil,
         backdropPath: String? = nil, overview: String? = nil,
         duration: TimeInterval? = nil, matchConfidence: Double? = nil,
         rating: Double? = nil, genreIDs: [Int]? = nil,
         sourceType: StorageSourceType = .quark) {
        self.id = id
        self.fileId = fileId
        self.mediaType = mediaType
        self.title = title
        self.year = year
        self.tmdbId = tmdbId
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.overview = overview
        self.duration = duration
        self.matchConfidence = matchConfidence
        self.rating = rating
        self.genreIDs = genreIDs
        self.sourceType = sourceType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileId = try container.decode(String.self, forKey: .fileId)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        title = try container.decode(String.self, forKey: .title)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        tmdbId = try container.decodeIfPresent(Int.self, forKey: .tmdbId)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        matchConfidence = try container.decodeIfPresent(Double.self, forKey: .matchConfidence)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        genreIDs = try container.decodeIfPresent([Int].self, forKey: .genreIDs)
        sourceType = try container.decodeIfPresent(StorageSourceType.self, forKey: .sourceType) ?? .quark
    }
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
