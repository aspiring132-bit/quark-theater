import Foundation

struct TMDBSearchResult: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let genreIDs: [Int]?
    /// The endpoint that produced this result. Legacy callers may leave this nil.
    var sourceMediaType: MediaType?
    var displayTitle: String { title ?? name ?? "未知标题" }
    var effectiveOriginalTitle: String { originalTitle ?? originalName ?? displayTitle }
    var year: Int? { Int((releaseDate ?? firstAirDate ?? "").prefix(4)) }

    init(id: Int, title: String? = nil, name: String? = nil, originalTitle: String? = nil, originalName: String? = nil,
         releaseDate: String? = nil, firstAirDate: String? = nil, overview: String? = nil,
         posterPath: String? = nil, backdropPath: String? = nil, voteAverage: Double? = nil, genreIDs: [Int]? = nil) {
        self.id = id
        self.title = title
        self.name = name
        self.originalTitle = originalTitle
        self.originalName = originalName
        self.releaseDate = releaseDate
        self.firstAirDate = firstAirDate
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.voteAverage = voteAverage
        self.genreIDs = genreIDs
    }

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case originalTitle = "original_title", originalName = "original_name"
        case releaseDate = "release_date", firstAirDate = "first_air_date"
        case posterPath = "poster_path", backdropPath = "backdrop_path"
        case voteAverage = "vote_average", genreIDs = "genre_ids"
    }

    init(id: Int, title: String?, name: String?, originalTitle: String?, originalName: String?,
         releaseDate: String?, firstAirDate: String?, overview: String?, posterPath: String?,
         backdropPath: String?, voteAverage: Double?, genreIDs: [Int]?, sourceMediaType: MediaType? = nil) {
        self.id = id; self.title = title; self.name = name; self.originalTitle = originalTitle; self.originalName = originalName
        self.releaseDate = releaseDate; self.firstAirDate = firstAirDate; self.overview = overview; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.voteAverage = voteAverage; self.genreIDs = genreIDs; self.sourceMediaType = sourceMediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); title = try c.decodeIfPresent(String.self, forKey: .title)
        name = try c.decodeIfPresent(String.self, forKey: .name); originalTitle = try c.decodeIfPresent(String.self, forKey: .originalTitle)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName); releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        firstAirDate = try c.decodeIfPresent(String.self, forKey: .firstAirDate); overview = try c.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath); backdropPath = try c.decodeIfPresent(String.self, forKey: .backdropPath)
        voteAverage = try c.decodeIfPresent(Double.self, forKey: .voteAverage); genreIDs = try c.decodeIfPresent([Int].self, forKey: .genreIDs)
        sourceMediaType = nil
    }
}

struct TMDBSearchResponse: Decodable { let results: [TMDBSearchResult] }

enum TMDBError: Error, LocalizedError {
    case missingAPIKey, badResponse, rejected(Int)
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请在设置中配置 TMDB API Read Access Token。"
        case .badResponse: return "TMDB 返回了无法识别的响应。"
        case .rejected(let code): return "TMDB 请求失败（HTTP \(code)）。"
        }
    }
}

/// Native TMDB scraper with homophone/alias resolution and multi-level query cascade.
struct TMDBService {
    static let builtInAPIKey = "94487d9bbfda56096618e82f65d86377"
    private let session: URLSession
    private let diagnostics: Diagnostics?

    init(session: URLSession = .shared, diagnostics: Diagnostics? = nil) {
        self.session = session
        self.diagnostics = diagnostics
    }

    func search(
        _ parsed: ParsedMediaName,
        apiReadToken: String?,
        language: String? = nil,
        parentFolderName: String? = nil,
        ancestorFolderName: String? = nil
    ) async throws -> [TMDBSearchResult] {
        let correlationID = await diagnostics?.makeCorrelationID()
        let startedAt = Date()
        let preferredLanguage = language ?? UserDefaults.standard.string(forKey: "scraperLanguage") ?? "zh-CN"
        let token = (apiReadToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = token.isEmpty ? Self.builtInAPIKey : token
        let type = parsed.mediaType == .series ? "tv" : "movie"

        // Guard against bare number scraping like "(09)" or "9" with no series context
        let isBareNumber = parsed.title.range(of: #"^\(?\d{1,3}\)?$"#, options: .regularExpression) != nil
        if isBareNumber && (parentFolderName == nil || parentFolderName?.contains("来自：") == true) && ancestorFolderName == nil {
            await recordSearchSummary(correlationID: correlationID, startedAt: startedAt, outcome: .noMatch, candidateCount: 0)
            return [] // Refuse to match bare numbers to movies like "9号谋杀案"
        }

        // Build query candidates cascade. The order is stable and all variants
        // are executed; a single successful response must not hide later aliases.
        var rawCandidates: [String] = []

        // 1. Base title
        if !isBareNumber {
            rawCandidates.append(contentsOf: MediaAliasResolver.variants(for: parsed.title))
            let colonStripped = colonStrip(parsed.title)
            if colonStripped != parsed.title { rawCandidates.append(colonStripped) }
            let numStripped = trailingNumberStrip(colonStripped)
            if numStripped != colonStripped && !numStripped.isEmpty { rawCandidates.append(numStripped) }
        }

        // Parent / ancestor folder titles (e.g. "G 高堡奇人S01~S04").
        for folder in [ancestorFolderName, parentFolderName].compactMap({ $0 }) {
            if !folder.contains("来自：") && !folder.contains("网盘") {
                if let ft = FilenameParser.folderTitle(folder) {
                    rawCandidates.append(ft)
                    rawCandidates.append(contentsOf: MediaAliasResolver.variants(for: ft))
                }
            }
        }

        // Deduplicate while preserving priority order
        var seen = Set<String>()
        var queryVariants: [String] = []
        for c in rawCandidates {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never query TMDB with pure numbers like "01", "04", "(09)"
            if trimmed.range(of: #"^\(?\d{1,4}\)?$"#, options: .regularExpression) != nil {
                continue
            }
            if !trimmed.isEmpty && trimmed.count > 1 && seen.insert(trimmed.lowercased()).inserted {
                queryVariants.append(trimmed)
            }
        }
        // Keep each logical search bounded: at most two query variants and
        // eight HTTP requests (two media types × two languages per query).
        // MediaLibrary may perform one learned-alias fallback, so the total
        // rematch budget remains at most sixteen requests per candidate.
        queryVariants = Array(queryVariants.prefix(2))

        if queryVariants.isEmpty {
            await recordSearchSummary(correlationID: correlationID, startedAt: startedAt, outcome: .noMatch, candidateCount: 0)
            return []
        }

        var aggregate: [String: TMDBSearchResult] = [:]
        var firstError: Error?
        var requestCount = 0
        requestLoop: for query in queryVariants {
            var languages = [preferredLanguage]
            if preferredLanguage.hasPrefix("zh") { languages.append("en-US") }
            let types = [type, type == "tv" ? "movie" : "tv"]
            for requestedType in types {
                for currentLanguage in languages {
                    guard requestCount < 8 else { break requestLoop }
                    requestCount += 1
                    try Task.checkCancellation()
                    do {
                        let rows = try await performSearch(title: query, type: requestedType, key: effectiveKey, language: currentLanguage, correlationID: correlationID)
                        for var row in rows {
                            row.sourceMediaType = requestedType == "tv" ? .series : .movie
                            let key = "\(row.sourceMediaType?.rawValue ?? "unknown"): \(row.id)"
                            aggregate[key] = aggregate[key] ?? row
                        }
                    } catch { firstError = firstError ?? error }
                }
            }
        }
        if aggregate.isEmpty, let firstError {
            await recordSearchSummary(correlationID: correlationID, startedAt: startedAt, outcome: .failed, candidateCount: 0)
            throw firstError
        }
        let outcome: DiagnosticOutcome = firstError == nil ? (aggregate.isEmpty ? .noMatch : .succeeded) : .partial
        await recordSearchSummary(correlationID: correlationID, startedAt: startedAt, outcome: outcome, candidateCount: aggregate.count)
        return Array(aggregate.values).sorted {
            let leftType = $0.sourceMediaType?.rawValue ?? ""
            let rightType = $1.sourceMediaType?.rawValue ?? ""
            if leftType != rightType { return leftType < rightType }
            return $0.id < $1.id
        }
    }

    private func performSearch(title: String, type: String, key: String, language: String, correlationID: DiagnosticCorrelationID?) async throws -> [TMDBSearchResult] {
        let startedAt = Date()
        guard var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(type)") else {
            await recordRequestFailure(correlationID: correlationID, startedAt: startedAt, reason: .invalidResponse)
            throw TMDBError.badResponse
        }
        var queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        var requestHeaders: [String: String] = ["Accept": "application/json"]
        if key.hasPrefix("eyJ") {
            requestHeaders["Authorization"] = "Bearer \(key)"
        } else {
            queryItems.append(URLQueryItem(name: "api_key", value: key))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw TMDBError.badResponse }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await recordRequestFailure(correlationID: correlationID, startedAt: startedAt, reason: .invalidResponse)
                throw TMDBError.badResponse
            }
            guard (200...299).contains(http.statusCode) else {
                await recordRequestFailure(correlationID: correlationID, startedAt: startedAt, status: http.statusCode, reason: .unavailable)
                throw TMDBError.rejected(http.statusCode)
            }
            guard let rows = try? JSONDecoder().decode(TMDBSearchResponse.self, from: data).results else {
                await recordRequestFailure(correlationID: correlationID, startedAt: startedAt, status: http.statusCode, reason: .invalidResponse)
                throw TMDBError.badResponse
            }
            await recordRequestCompleted(correlationID: correlationID, startedAt: startedAt, status: http.statusCode, candidateCount: rows.count)
            return rows
        } catch {
            if error is TMDBError { throw error }
            await recordRequestFailure(correlationID: correlationID, startedAt: startedAt, reason: diagnosticReason(for: error))
            throw error
        }
    }

    private func recordRequestCompleted(correlationID: DiagnosticCorrelationID?, startedAt: Date, status: Int, candidateCount: Int) async {
        await diagnostics?.record(category: .scraping, level: .debug, event: .requestCompleted, correlationID: correlationID, metadata: [
            .host(.tmdbAPI), .stage(.search), .httpStatus(status), .latencyMilliseconds(elapsedMilliseconds(since: startedAt)),
            .candidateCount(candidateCount), .outcome(.succeeded), .status(.completed)
        ])
    }

    private func recordRequestFailure(correlationID: DiagnosticCorrelationID?, startedAt: Date, status: Int? = nil, reason: DiagnosticReason) async {
        var metadata: [DiagnosticMetadata] = [
            .host(.tmdbAPI), .stage(.search), .latencyMilliseconds(elapsedMilliseconds(since: startedAt)),
            .outcome(.failed), .reason(reason), .status(.failed)
        ]
        if let status { metadata.append(.httpStatus(status)) }
        await diagnostics?.record(category: .scraping, level: .warning, event: .requestFailed, correlationID: correlationID, metadata: metadata)
    }

    private func recordSearchSummary(correlationID: DiagnosticCorrelationID?, startedAt: Date, outcome: DiagnosticOutcome, candidateCount: Int) async {
        await diagnostics?.record(category: .scraping, level: outcome == .failed ? .warning : .info, event: outcome == .failed ? .scrapingSearchFailed : .scrapingSearchCompleted, correlationID: correlationID, metadata: [
            .host(.tmdbAPI), .stage(.disposition), .latencyMilliseconds(elapsedMilliseconds(since: startedAt)),
            .candidateCount(candidateCount), .outcome(outcome), .status(outcome == .failed ? .failed : .completed)
        ])
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }

    private func diagnosticReason(for error: Error) -> DiagnosticReason {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost: return .networkUnavailable
            default: return .unavailable
            }
        }
        return .unknown
    }

    // MARK: - Title Normalisation Helpers

    private func colonStrip(_ s: String) -> String {
        let colonChars = CharacterSet(charactersIn: "：:")
        if let r = s.rangeOfCharacter(from: colonChars) {
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private func trailingNumberStrip(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[0-9０-９]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
