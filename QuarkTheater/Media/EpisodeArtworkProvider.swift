import Foundation

/// A fully-resolved artwork lookup for one cloud file: both the season and
/// the episode number must be known from confirmed metadata (preferred) or
/// filename parsing. Files without both never produce a request — episode
/// numbers are never inferred from list position.
struct EpisodeArtworkRequest: Equatable, Sendable {
    let seasonNumber: Int
    let episodeNumber: Int
}

/// Decides which queue entries may ask TMDB for per-episode artwork.
enum EpisodeArtworkResolver {
    static func requests(
        seriesTMDBId: Int?,
        metadataByFileID: [String: ParsedMediaName]
    ) -> [String: EpisodeArtworkRequest] {
        guard seriesTMDBId != nil else { return [:] }
        var result: [String: EpisodeArtworkRequest] = [:]
        for (fileID, parsed) in metadataByFileID {
            guard let season = parsed.seasonNumber, let episode = parsed.episodeNumber else { continue }
            result[fileID] = EpisodeArtworkRequest(seasonNumber: season, episodeNumber: episode)
        }
        return result
    }
}

/// Caches TMDB season-details responses keyed by `(series ID, season)` and
/// deduplicates in-flight requests, so a full drawer of episode cards costs
/// at most one HTTP request per season. Failed fetches are not cached.
///
/// Artwork resolution is kept strictly separate from playback identity:
/// the provider only maps already-known season/episode numbers to still
/// images and never feeds back into matching or queue ordering.
actor EpisodeArtworkProvider {
    struct SeasonKey: Hashable, Sendable {
        let seriesID: Int
        let seasonNumber: Int
    }

    /// Episode number → optional still path (nil when TMDB has no artwork).
    typealias SeasonStillMap = [Int: String?]

    private let fetchSeason: @Sendable (SeasonKey) async throws -> SeasonStillMap
    private var cache: [SeasonKey: SeasonStillMap] = [:]
    private var inFlight: [SeasonKey: Task<SeasonStillMap, Error>] = [:]

    /// Test seam: inject a deterministic season fetch.
    init(fetchSeason: @escaping @Sendable (SeasonKey) async throws -> SeasonStillMap) {
        self.fetchSeason = fetchSeason
    }

    init(service: TMDBService, apiReadToken: String? = nil, language: String? = nil) {
        self.fetchSeason = { key in
            let details = try await service.seasonDetails(
                seriesID: key.seriesID,
                seasonNumber: key.seasonNumber,
                apiReadToken: apiReadToken,
                language: language
            )
            return details.stillPathByEpisode
        }
    }

    /// Resolve still image URLs for a batch of files. At most one season
    /// request is issued per distinct season in `requests`.
    func stillURLs(seriesID: Int, requests: [String: EpisodeArtworkRequest]) async -> [String: URL] {
        var seasonsNeeded = Set<SeasonKey>()
        for request in requests.values {
            seasonsNeeded.insert(SeasonKey(seriesID: seriesID, seasonNumber: request.seasonNumber))
        }
        var maps: [SeasonKey: SeasonStillMap] = [:]
        for key in seasonsNeeded {
            if let map = try? await seasonMap(for: key) {
                maps[key] = map
            }
        }
        var urls: [String: URL] = [:]
        for (fileID, request) in requests {
            let key = SeasonKey(seriesID: seriesID, seasonNumber: request.seasonNumber)
            guard let stillPath = maps[key]?[request.episodeNumber] ?? nil else { continue }
            if let url = Self.imageURL(stillPath: stillPath) {
                urls[fileID] = url
            }
        }
        return urls
    }

    func stillURL(seriesID: Int, seasonNumber: Int, episodeNumber: Int) async -> URL? {
        let key = SeasonKey(seriesID: seriesID, seasonNumber: seasonNumber)
        guard let map = try? await seasonMap(for: key),
              let stillPath = map[episodeNumber] ?? nil else { return nil }
        return Self.imageURL(stillPath: stillPath)
    }

    private func seasonMap(for key: SeasonKey) async throws -> SeasonStillMap {
        if let cached = cache[key] { return cached }
        if let pending = inFlight[key] { return try await pending.value }
        let task = Task<SeasonStillMap, Error> { try await fetchSeason(key) }
        inFlight[key] = task
        do {
            let map = try await task.value
            cache[key] = map
            inFlight[key] = nil
            return map
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    /// TMDB image-host convention shared with the rest of the app
    /// (`https://image.tmdb.org/t/p/<size><path>`).
    static func imageURL(stillPath: String, size: String = "w780") -> URL? {
        guard !stillPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(stillPath)")
    }
}
