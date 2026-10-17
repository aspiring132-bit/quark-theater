import Foundation

struct TMDBSearchResult: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let genreIDs: [Int]?
    var displayTitle: String { title ?? name ?? "未知标题" }
    var year: Int? { Int((releaseDate ?? firstAirDate ?? "").prefix(4)) }
    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case releaseDate = "release_date", firstAirDate = "first_air_date"
        case posterPath = "poster_path", backdropPath = "backdrop_path"
        case voteAverage = "vote_average", genreIDs = "genre_ids"
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

/// Native TMDB scraper with multi-query fallback strategy.
/// Query cascade for any given title:
///   1. Primary title  → preferred language (zh-CN)
///   2. Primary title  → English (en-US)  [if zh-CN returned nothing]
///   3. Title without Chinese colon suffix (e.g. "蛛丝4" from "蛛丝4：焕然一新")
///   4. Title without trailing numeric suffix (e.g. "蛛丝" from "蛛丝4")
///   5. Raw parentFolderName (stripped of season markers) as a last resort
struct TMDBService {
    static let builtInAPIKey = "94487d9bbfda56096618e82f65d86377"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(
        _ parsed: ParsedMediaName,
        apiReadToken: String?,
        language: String? = nil,
        parentFolderName: String? = nil
    ) async throws -> [TMDBSearchResult] {
        let preferredLanguage = language ?? UserDefaults.standard.string(forKey: "scraperLanguage") ?? "zh-CN"
        let token = (apiReadToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = token.isEmpty ? Self.builtInAPIKey : token
        let type = parsed.mediaType == .series ? "tv" : "movie"

        // Build query cascade
        var queryVariants: [String] = []
        queryVariants.append(parsed.title)

        // Variant: strip Chinese/full-width colon suffix  "蛛丝4：焕然一新" → "蛛丝4"
        let colonStripped = colonStrip(parsed.title)
        if colonStripped != parsed.title { queryVariants.append(colonStripped) }

        // Variant: strip trailing number "蛛丝4" → "蛛丝"
        let numStripped = trailingNumberStrip(colonStripped)
        if numStripped != colonStripped && !numStripped.isEmpty { queryVariants.append(numStripped) }

        // Variant: parent folder name (stripped) as a last-resort show title
        if let folderTitle = FilenameParser.folderTitle(parentFolderName),
           !queryVariants.contains(where: { $0.lowercased() == folderTitle.lowercased() }) {
            queryVariants.append(folderTitle)
        }

        // Search with cascade: try each query in zh-CN first, then en-US
        for query in queryVariants {
            let zhResults = try await performSearch(title: query, type: type, key: effectiveKey, language: preferredLanguage)
            if !zhResults.isEmpty { return zhResults }

            if preferredLanguage.hasPrefix("zh") {
                let enResults = try await performSearch(title: query, type: type, key: effectiveKey, language: "en-US")
                if !enResults.isEmpty { return enResults }
            }
        }

        return []
    }

    private func performSearch(title: String, type: String, key: String, language: String) async throws -> [TMDBSearchResult] {
        guard var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(type)") else {
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw TMDBError.rejected(http.statusCode) }
        return (try? JSONDecoder().decode(TMDBSearchResponse.self, from: data).results) ?? []
    }

    // MARK: - Title Normalisation Helpers

    /// Strip content after a Chinese/full-width colon: "蛛丝4：焕然一新" → "蛛丝4"
    private func colonStrip(_ s: String) -> String {
        let colonChars = CharacterSet(charactersIn: "：:")
        if let r = s.rangeOfCharacter(from: colonChars) {
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Strip trailing arabic/CJK digit: "蛛丝4" → "蛛丝", "Season2" → "Season"
    private func trailingNumberStrip(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[0-9０-９]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
