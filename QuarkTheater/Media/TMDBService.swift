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

/// Native TMDB scraper supporting built-in community key and custom user token, with Chinese/English localization.
struct TMDBService {
    static let builtInAPIKey = "94487d9bbfda56096618e82f65d86377"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(_ parsed: ParsedMediaName, apiReadToken: String?, language: String? = nil) async throws -> [TMDBSearchResult] {
        let preferredLanguage = language ?? UserDefaults.standard.string(forKey: "scraperLanguage") ?? "zh-CN"
        let token = (apiReadToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = token.isEmpty ? Self.builtInAPIKey : token

        let type = parsed.mediaType == .series ? "tv" : "movie"
        var results = try await performSearch(title: parsed.title, type: type, key: effectiveKey, language: preferredLanguage)

        // If no results found in Chinese, and title appears to be English, fallback to search in English
        if results.isEmpty && preferredLanguage.hasPrefix("zh") {
            results = try await performSearch(title: parsed.title, type: type, key: effectiveKey, language: "en-US")
        }

        return results
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

        var requestHeaders: [String: String] = [
            "Accept": "application/json"
        ]

        if key.hasPrefix("eyJ") {
            // v4 Bearer Read Access Token
            requestHeaders["Authorization"] = "Bearer \(key)"
        } else {
            // v3 API Key
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
}
