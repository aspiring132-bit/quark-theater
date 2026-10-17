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

/// Uses a user-provided v4 read token in memory only. Never logs or persists the token.
struct TMDBService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func search(_ parsed: ParsedMediaName, apiReadToken: String, language: String = "zh-CN") async throws -> [TMDBSearchResult] {
        let token = apiReadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TMDBError.missingAPIKey }
        let type = parsed.mediaType == .series ? "tv" : "movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(type)")!
        components.queryItems = [URLQueryItem(name: "query", value: parsed.title),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_adult", value: "false")]
        guard let url = components.url else { throw TMDBError.badResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw TMDBError.rejected(http.statusCode) }
        return try JSONDecoder().decode(TMDBSearchResponse.self, from: data).results
    }
}
