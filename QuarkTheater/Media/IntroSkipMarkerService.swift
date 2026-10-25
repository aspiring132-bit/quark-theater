import Foundation

/// Service that coordinates TheIntroDB and SkipDB to fetch, validate, and cache
/// intro/credits markers for television episodes (F-001).
@MainActor
final class IntroSkipMarkerService {
    static let shared = IntroSkipMarkerService()

    private let session: URLSession
    private let tmdbService: TMDBService

    // In-memory caches with expiration support
    private struct CacheEntry<T> {
        let value: T? // nil represents negative cache (not found)
        let expiresAt: Date
    }

    private var introDBCache: [String: CacheEntry<TheIntroDBSegments>] = [:]
    private var skipDBCache: [String: CacheEntry<SkipDBSegments>] = [:]
    private var imdbIDCache: [Int: CacheEntry<String>] = [:]

    private let positiveCacheTTL: TimeInterval = 24 * 3600 // 24 hours
    private let negativeCacheTTL: TimeInterval = 1800      // 30 minutes

    init(session: URLSession = .shared, tmdbService: TMDBService = TMDBService()) {
        self.session = session
        self.tmdbService = tmdbService
    }

    // MARK: - Public API

    /// Fetch intro and outro markers using both TheIntroDB and SkipDB.
    /// Fails soft on any network or parsing error without blocking playback.
    func resolveMarkers(
        tmdbID: Int,
        season: Int,
        episode: Int,
        duration: Double,
        fileID: String,
        repository: MediaCatalogRepository?,
        tmdbToken: String?
    ) async -> ResolvedEpisodeMarkers {
        guard tmdbID > 0, season >= 0, episode > 0, duration.isFinite, duration > 0 else { return .empty }

        // 1. Fetch TheIntroDB (keyed by tmdbID, season, episode, fileID)
        async let introDBTask = fetchTheIntroDB(
            tmdbID: tmdbID,
            season: season,
            episode: episode,
            fileID: fileID,
            repository: repository
        )

        // 2. Fetch SkipDB (requires IMDb ID from TMDB series external IDs)
        async let skipDBTask = fetchSkipDB(
            tmdbID: tmdbID,
            season: season,
            episode: episode,
            fileID: fileID,
            repository: repository,
            tmdbToken: tmdbToken
        )

        let introDBSegments = await introDBTask
        let skipDBSegments = await skipDBTask

        // 3. Validate and resolve conflicts conservatively
        return validateAndMerge(
            introDB: introDBSegments,
            skipDB: skipDBSegments,
            duration: duration
        )
    }

    // MARK: - TheIntroDB Client

    private struct TheIntroDBSegments: Equatable {
        let intro: PlaybackSegmentRange?
        let credits: PlaybackSegmentRange?
    }

    private func fetchTheIntroDB(
        tmdbID: Int,
        season: Int,
        episode: Int,
        fileID: String,
        repository: MediaCatalogRepository?
    ) async -> TheIntroDBSegments? {
        let key = "introdb:tmdb_\(tmdbID):s\(season):e\(episode):file_\(fileID)"
        let now = Date()

        // 1. Check in-memory cache
        if let cached = introDBCache[key], cached.expiresAt > now {
            return cached.value
        }

        // 2. Check persistent SQLite cache
        if let persisted = repository?.markerCache(key: key), persisted.expiresAt > now {
            let segments = TheIntroDBSegments(intro: persisted.intro, credits: persisted.outro)
            introDBCache[key] = CacheEntry(value: segments, expiresAt: persisted.expiresAt)
            return segments
        }

        // 3. Network fetch
        guard var components = URLComponents(string: "https://api.theintrodb.org/v4/media") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "tmdb_id", value: String(tmdbID)),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            if http.statusCode == 404 {
                let expiresAt = now.addingTimeInterval(negativeCacheTTL)
                introDBCache[key] = CacheEntry(value: nil, expiresAt: expiresAt)
                let payload = MarkerCachePayload(intro: nil, outro: nil, fetchedAt: now, expiresAt: expiresAt)
                repository?.saveMarkerCache(key: key, provider: "theintrodb", tmdbID: tmdbID, season: season, episode: episode, fileID: fileID, payload: payload)
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                return nil
            }

            guard let parsed = parseTheIntroDBResponse(data: data) else {
                // 若 JSON/字段格式无法解析则不写缓存，返回 nil，确保临时 schema/网络错误不被缓存
                return nil
            }

            let hasValidMarker = (parsed.intro != nil || parsed.credits != nil)
            let ttl = hasValidMarker ? positiveCacheTTL : negativeCacheTTL
            let expiresAt = now.addingTimeInterval(ttl)

            introDBCache[key] = CacheEntry(value: parsed, expiresAt: expiresAt)
            let payload = MarkerCachePayload(
                intro: parsed.intro,
                outro: parsed.credits,
                fetchedAt: now,
                expiresAt: expiresAt
            )
            repository?.saveMarkerCache(
                key: key,
                provider: "theintrodb",
                tmdbID: tmdbID,
                season: season,
                episode: episode,
                fileID: fileID,
                payload: payload
            )
            return parsed
        } catch {
            return nil
        }
    }

    private func parseTheIntroDBResponse(data: Data) -> TheIntroDBSegments? {
        // 只有合法响应结构（含 intro 或 credits 字段）才接受
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["intro"] != nil || json["credits"] != nil) else {
            return nil
        }

        struct TimeItem: Decodable {
            let start_ms: Double?
            let end_ms: Double?
            let startMs: Double?
            let endMs: Double?

            var startSeconds: Double? {
                (start_ms ?? startMs).map { $0 / 1000.0 }
            }
            var endSeconds: Double? {
                (end_ms ?? endMs).map { $0 / 1000.0 }
            }
        }
        struct Root: Decodable {
            let intro: [TimeItem]?
            let credits: [TimeItem]?
        }

        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return nil }
        var introRange: PlaybackSegmentRange?
        if let firstIntro = root.intro?.first,
           let s = firstIntro.startSeconds, let e = firstIntro.endSeconds,
           s.isFinite, e.isFinite, s >= 0, e > s {
            introRange = PlaybackSegmentRange(startSeconds: s, endSeconds: e)
        }
        var creditsRange: PlaybackSegmentRange?
        if let firstCredit = root.credits?.first,
           let s = firstCredit.startSeconds, let e = firstCredit.endSeconds,
           s.isFinite, e.isFinite, s >= 0, e > s {
            creditsRange = PlaybackSegmentRange(startSeconds: s, endSeconds: e)
        }
        return TheIntroDBSegments(intro: introRange, credits: creditsRange)
    }

    // MARK: - SkipDB Client

    private struct SkipDBSegments: Equatable {
        let intro: PlaybackSegmentRange?
        let outro: PlaybackSegmentRange?
    }

    private func fetchSkipDB(
        tmdbID: Int,
        season: Int,
        episode: Int,
        fileID: String,
        repository: MediaCatalogRepository?,
        tmdbToken: String?
    ) async -> SkipDBSegments? {
        let key = "skipdb:tmdb_\(tmdbID):s\(season):e\(episode):file_\(fileID)"
        let now = Date()

        // 1. Check in-memory cache
        if let cached = skipDBCache[key], cached.expiresAt > now {
            return cached.value
        }

        // 2. Check persistent SQLite cache
        if let persisted = repository?.markerCache(key: key), persisted.expiresAt > now {
            let segments = SkipDBSegments(intro: persisted.intro, outro: persisted.outro)
            skipDBCache[key] = CacheEntry(value: segments, expiresAt: persisted.expiresAt)
            return segments
        }

        // 3. Resolve IMDb ID from TMDB
        guard let imdbID = await resolveIMDbID(tmdbID: tmdbID, tmdbToken: tmdbToken), !imdbID.isEmpty else {
            let expiresAt = now.addingTimeInterval(negativeCacheTTL)
            skipDBCache[key] = CacheEntry(value: nil, expiresAt: expiresAt)
            let payload = MarkerCachePayload(intro: nil, outro: nil, fetchedAt: now, expiresAt: expiresAt)
            repository?.saveMarkerCache(key: key, provider: "skipdb", tmdbID: tmdbID, season: season, episode: episode, fileID: fileID, payload: payload)
            return nil
        }

        // 4. Network fetch
        guard var components = URLComponents(string: "https://skipdb.tv/api/segments") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbID),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 {
                let expiresAt = now.addingTimeInterval(negativeCacheTTL)
                skipDBCache[key] = CacheEntry(value: nil, expiresAt: expiresAt)
                let payload = MarkerCachePayload(intro: nil, outro: nil, fetchedAt: now, expiresAt: expiresAt)
                repository?.saveMarkerCache(key: key, provider: "skipdb", tmdbID: tmdbID, season: season, episode: episode, fileID: fileID, payload: payload)
                return nil
            }
            guard (200...299).contains(http.statusCode) else { return nil }

            guard let parsed = parseSkipDBResponse(data: data) else {
                // 若 JSON/字段格式无法解析则不写缓存，返回 nil，确保临时 schema/网络错误不被缓存
                return nil
            }

            let hasValidMarker = (parsed.intro != nil || parsed.outro != nil)
            let ttl = hasValidMarker ? positiveCacheTTL : negativeCacheTTL
            let expiresAt = now.addingTimeInterval(ttl)

            skipDBCache[key] = CacheEntry(value: parsed, expiresAt: expiresAt)
            let payload = MarkerCachePayload(
                intro: parsed.intro,
                outro: parsed.outro,
                fetchedAt: now,
                expiresAt: expiresAt
            )
            repository?.saveMarkerCache(
                key: key,
                provider: "skipdb",
                tmdbID: tmdbID,
                season: season,
                episode: episode,
                fileID: fileID,
                payload: payload
            )
            return parsed
        } catch {
            return nil
        }
    }

    private func parseSkipDBResponse(data: Data) -> SkipDBSegments? {
        // 只有合法响应结构（含 segments 字段）才接受
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["segments"] != nil else {
            return nil
        }

        struct SegmentItem: Decodable {
            let type: String?
            let start_ms: Double?
            let end_ms: Double?
            let startMs: Double?
            let endMs: Double?

            var startSeconds: Double? { (start_ms ?? startMs).map { $0 / 1000.0 } }
            var endSeconds: Double? { (end_ms ?? endMs).map { $0 / 1000.0 } }
        }

        struct SegmentsDict: Decodable {
            let intro: SegmentItem?
            let outro: SegmentItem?
            let recap: SegmentItem?
            let preview: SegmentItem?
        }

        struct RootObject: Decodable {
            let segments: SegmentsDict?
        }

        struct RootArray: Decodable {
            let segments: [SegmentItem]?
        }

        if let root = try? JSONDecoder().decode(RootObject.self, from: data) {
            var introRange: PlaybackSegmentRange?
            var outroRange: PlaybackSegmentRange?
            if let dict = root.segments {
                if let intro = dict.intro, let s = intro.startSeconds, let e = intro.endSeconds,
                   s.isFinite, e.isFinite, s >= 0, e > s {
                    introRange = PlaybackSegmentRange(startSeconds: s, endSeconds: e)
                }
                if let outro = dict.outro, let s = outro.startSeconds, let e = outro.endSeconds,
                   s.isFinite, e.isFinite, s >= 0, e > s {
                    outroRange = PlaybackSegmentRange(startSeconds: s, endSeconds: e)
                }
            }
            return SkipDBSegments(intro: introRange, outro: outroRange)
        }

        if let root = try? JSONDecoder().decode(RootArray.self, from: data) {
            var introRange: PlaybackSegmentRange?
            var outroRange: PlaybackSegmentRange?
            for item in (root.segments ?? []) {
                guard let type = item.type?.lowercased(),
                      let s = item.startSeconds, let e = item.endSeconds,
                      s.isFinite, e.isFinite, s >= 0, e > s else { continue }
                if type == "intro" && introRange == nil {
                    introRange = PlaybackSegmentRange(startSeconds: s, endSeconds: e)
                } else if type == "outro" && outroRange == nil {
                    outroRange = PlaybackSegmentRange(startSeconds: s, endSeconds: e)
                }
            }
            return SkipDBSegments(intro: introRange, outro: outroRange)
        }

        return nil
    }

    private func resolveIMDbID(tmdbID: Int, tmdbToken: String?) async -> String? {
        let now = Date()
        if let cached = imdbIDCache[tmdbID], cached.expiresAt > now {
            return cached.value
        }

        do {
            let externalIDs = try await tmdbService.seriesExternalIDs(seriesID: tmdbID, apiReadToken: tmdbToken)
            if let imdb = externalIDs.imdbId, !imdb.isEmpty {
                imdbIDCache[tmdbID] = CacheEntry(value: imdb, expiresAt: now.addingTimeInterval(positiveCacheTTL * 7))
                return imdb
            } else {
                imdbIDCache[tmdbID] = CacheEntry(value: nil, expiresAt: now.addingTimeInterval(negativeCacheTTL))
                return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - Validation & Conservative Merging

    private func validateAndMerge(
        introDB: TheIntroDBSegments?,
        skipDB: SkipDBSegments?,
        duration: Double
    ) -> ResolvedEpisodeMarkers {
        guard duration.isFinite && duration > 0 else { return .empty }

        let intro1 = introDB?.intro.flatMap { validateIntro($0, duration: duration) }
        let intro2 = skipDB?.intro.flatMap { validateIntro($0, duration: duration) }

        let outro1 = introDB?.credits.flatMap { validateOutro($0, duration: duration) }
        let outro2 = skipDB?.outro.flatMap { validateOutro($0, duration: duration) }

        // Resolve intro conflict
        let resolvedIntro: PlaybackSegmentRange?
        if let i1 = intro1, let i2 = intro2 {
            let startDiff = abs(i1.startSeconds - i2.startSeconds)
            let endDiff = abs(i1.endSeconds - i2.endSeconds)
            if startDiff <= 5.0 && endDiff <= 5.0 {
                resolvedIntro = i1 // agree
            } else {
                // Conflict: conservatively hide button
                resolvedIntro = nil
            }
        } else {
            resolvedIntro = intro1 ?? intro2
        }

        // Resolve outro conflict
        let resolvedOutro: PlaybackSegmentRange?
        if let o1 = outro1, let o2 = outro2 {
            let startDiff = abs(o1.startSeconds - o2.startSeconds)
            let endDiff = abs(o1.endSeconds - o2.endSeconds)
            if startDiff <= 5.0 && endDiff <= 5.0 {
                resolvedOutro = o1 // agree
            } else {
                // Conflict: conservatively hide button
                resolvedOutro = nil
            }
        } else {
            resolvedOutro = outro1 ?? outro2
        }

        return ResolvedEpisodeMarkers(intro: resolvedIntro, outro: resolvedOutro)
    }

    private func validateIntro(_ range: PlaybackSegmentRange, duration: Double) -> PlaybackSegmentRange? {
        guard range.startSeconds.isFinite && range.endSeconds.isFinite else { return nil }
        guard range.startSeconds >= 0 && range.endSeconds > range.startSeconds else { return nil }
        let length = range.endSeconds - range.startSeconds
        guard length >= 5.0, length <= 300.0 else { return nil }
        if duration > 0 {
            guard range.endSeconds <= duration else { return nil }
            guard range.startSeconds <= duration * 0.45 else { return nil }
        }
        return range
    }

    private func validateOutro(_ range: PlaybackSegmentRange, duration: Double) -> PlaybackSegmentRange? {
        guard range.startSeconds.isFinite && range.endSeconds.isFinite else { return nil }
        guard range.startSeconds >= 0 && range.endSeconds > range.startSeconds else { return nil }
        let length = range.endSeconds - range.startSeconds
        guard length >= 5.0, length <= 600.0 else { return nil }
        if duration > 0 {
            guard range.startSeconds >= duration * 0.50 else { return nil }
            // If outro/credits end exceeds duration (e.g. by up to 5s), clamp to duration
            let clampedEnd = min(range.endSeconds, duration)
            guard clampedEnd > range.startSeconds else { return nil }
            return PlaybackSegmentRange(startSeconds: range.startSeconds, endSeconds: clampedEnd)
        }
        return range
    }

    // MARK: - Re-validation on Reception

    static func validateAndClamp(markers: ResolvedEpisodeMarkers, duration: Double) -> ResolvedEpisodeMarkers {
        guard duration.isFinite && duration > 0 else { return .empty }
        let validatedIntro: PlaybackSegmentRange?
        if let intro = markers.intro {
            let length = intro.endSeconds - intro.startSeconds
            if intro.startSeconds.isFinite && intro.endSeconds.isFinite &&
               intro.startSeconds >= 0 && intro.endSeconds <= duration &&
               length >= 5.0 && length <= 300.0 && intro.startSeconds <= duration * 0.45 {
                validatedIntro = intro
            } else {
                validatedIntro = nil
            }
        } else {
            validatedIntro = nil
        }

        let validatedOutro: PlaybackSegmentRange?
        if let outro = markers.outro {
            let clampedEnd = min(outro.endSeconds, duration)
            let length = clampedEnd - outro.startSeconds
            if outro.startSeconds.isFinite && outro.endSeconds.isFinite &&
               outro.startSeconds >= 0 && clampedEnd > outro.startSeconds &&
               outro.startSeconds >= duration * 0.50 && length >= 5.0 && length <= 600.0 {
                validatedOutro = PlaybackSegmentRange(startSeconds: outro.startSeconds, endSeconds: clampedEnd)
            } else {
                validatedOutro = nil
            }
        } else {
            validatedOutro = nil
        }

        return ResolvedEpisodeMarkers(intro: validatedIntro, outro: validatedOutro)
    }
}
