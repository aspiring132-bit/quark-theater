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
    var sourceID: String? = nil
    var id: String { fileId }
    var isVideo: Bool {
        !isDirectory && ["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "webm"].contains(fileExtension.lowercased())
    }

    init(
        fileId: String,
        parentId: String,
        name: String,
        size: Int64,
        fileExtension: String,
        modifiedAt: Date?,
        isDirectory: Bool,
        sourceID: String? = nil
    ) {
        self.fileId = fileId
        self.parentId = parentId
        self.name = name
        self.size = size
        self.fileExtension = fileExtension
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.sourceID = sourceID
    }

    enum CodingKeys: String, CodingKey {
        case fileId, parentId, name, size, fileExtension, modifiedAt, isDirectory
        case sourceID, sourceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileId = try container.decode(String.self, forKey: .fileId)
        parentId = try container.decode(String.self, forKey: .parentId)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decode(Int64.self, forKey: .size)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
            ?? container.decodeIfPresent(String.self, forKey: .sourceId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(parentId, forKey: .parentId)
        try container.encode(name, forKey: .name)
        try container.encode(size, forKey: .size)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encodeIfPresent(sourceID, forKey: .sourceID)
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
    var sourceId: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil

    var sourceID: String? {
        get { sourceId }
        set { sourceId = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case id, fileId, mediaType, title, year, tmdbId
        case posterPath, backdropPath, overview, duration
        case matchConfidence, rating, genreIDs, sourceType
        case sourceId, sourceID
        case seasonNumber, episodeNumber
    }

    init(id: String, fileId: String, mediaType: MediaType, title: String,
         year: Int? = nil, tmdbId: Int? = nil, posterPath: String? = nil,
         backdropPath: String? = nil, overview: String? = nil,
         duration: TimeInterval? = nil, matchConfidence: Double? = nil,
         rating: Double? = nil, genreIDs: [Int]? = nil,
         sourceType: StorageSourceType = .quark,
         sourceId: String? = nil,
         seasonNumber: Int? = nil, episodeNumber: Int? = nil) {
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
        self.sourceId = sourceId ?? (sourceType == .quark ? "quark-default" : nil)
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
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
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)
            ?? container.decodeIfPresent(String.self, forKey: .sourceID)
            ?? (sourceType == .quark ? "quark-default" : nil)
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(tmdbId, forKey: .tmdbId)
        try container.encodeIfPresent(posterPath, forKey: .posterPath)
        try container.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(matchConfidence, forKey: .matchConfidence)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(genreIDs, forKey: .genreIDs)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encodeIfPresent(sourceId, forKey: .sourceId)
        try container.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try container.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
    }
}

/// Canonical season/episode projection used by library and detail queues.
/// Confirmed catalog metadata wins over filename parsing; an unknown episode
/// remains unknown instead of being coerced to episode 1.
enum EpisodeMetadataProjection {
    static func project(metadata: MediaItem, parsed: ParsedMediaName) -> ParsedMediaName {
        ParsedMediaName(title: parsed.title, year: parsed.year ?? metadata.year,
                        mediaType: parsed.mediaType, seasonNumber: metadata.seasonNumber ?? parsed.seasonNumber,
                        // A confirmed catalog row is authoritative even when its
                        // episode number is deliberately unknown. Falling back to
                        // a filename's E01 would incorrectly make it autoplayable.
                        episodeNumber: metadata.episodeNumber,
                        inferredFromParent: parsed.inferredFromParent,
                        unresolvedReason: parsed.unresolvedReason)
    }

    static func displayEpisodeNumber(_ parsed: ParsedMediaName) -> Int? {
        parsed.episodeNumber
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
