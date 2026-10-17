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
    var displayTitle: String { title ?? name ?? "未知标题" }
    var effectiveOriginalTitle: String { originalTitle ?? originalName ?? displayTitle }
    var year: Int? { Int((releaseDate ?? firstAirDate ?? "").prefix(4)) }
    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case originalTitle = "original_title", originalName = "original_name"
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

/// Native TMDB scraper with homophone/alias resolution and multi-level query cascade.
struct TMDBService {
    static let builtInAPIKey = "94487d9bbfda56096618e82f65d86377"
    private let session: URLSession

    // Common copyrighted/homophone aliases used in cloud drive shares
    private static let commonAliases: [String: String] = [
        "蛛丝": "蜘蛛侠",
        "蜘蛛": "蜘蛛侠",
        "蛛网": "蜘蛛侠",
        "高堡弃人": "高堡奇人",
        "使女": "使女的故事",
        "大西洋": "大西洋帝国",
        "绝命": "绝命毒师",
        "权游": "权力的游戏",
        "绝命毒师": "绝命毒师",
        "西部世界": "西部世界"
    ]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(
        _ parsed: ParsedMediaName,
        apiReadToken: String?,
        language: String? = nil,
        parentFolderName: String? = nil,
        ancestorFolderName: String? = nil
    ) async throws -> [TMDBSearchResult] {
        let preferredLanguage = language ?? UserDefaults.standard.string(forKey: "scraperLanguage") ?? "zh-CN"
        let token = (apiReadToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = token.isEmpty ? Self.builtInAPIKey : token
        let type = parsed.mediaType == .series ? "tv" : "movie"

        // Guard against bare number scraping like "(09)" or "9" with no series context
        let isBareNumber = parsed.title.range(of: #"^\(?\d{1,3}\)?$"#, options: .regularExpression) != nil
        if isBareNumber && (parentFolderName == nil || parentFolderName?.contains("来自：") == true) && ancestorFolderName == nil {
            return [] // Refuse to match bare numbers to movies like "9号谋杀案"
        }

        // Build query candidates cascade
        var rawCandidates: [String] = []

        // 1. Base title
        if !isBareNumber {
            rawCandidates.append(parsed.title)
            let colonStripped = colonStrip(parsed.title)
            if colonStripped != parsed.title { rawCandidates.append(colonStripped) }
            let numStripped = trailingNumberStrip(colonStripped)
            if numStripped != colonStripped && !numStripped.isEmpty { rawCandidates.append(numStripped) }
        }

        // 2. Add alias / homophone replacements (e.g. 蛛丝4 -> 蜘蛛侠4 -> 蜘蛛侠)
        for (homophone, standard) in Self.commonAliases {
            for cand in rawCandidates {
                if cand.contains(homophone) {
                    let replaced = cand.replacingOccurrences(of: homophone, with: standard)
                    rawCandidates.append(replaced)
                    rawCandidates.append(standard)
                }
            }
        }

        // 3. Parent / Ancestor Folder Titles (e.g. "G 高堡奇人S01~S04")
        for folder in [ancestorFolderName, parentFolderName].compactMap({ $0 }) {
            if !folder.contains("来自：") && !folder.contains("网盘") {
                if let ft = FilenameParser.folderTitle(folder) {
                    rawCandidates.append(ft)
                    for (homophone, standard) in Self.commonAliases {
                        if ft.contains(homophone) {
                            rawCandidates.append(ft.replacingOccurrences(of: homophone, with: standard))
                            rawCandidates.append(standard)
                        }
                    }
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

        // 4. Perform search: try each query variant
        for query in queryVariants {
            // First try preferred language (zh-CN)
            let zhResults = try await performSearch(title: query, type: type, key: effectiveKey, language: preferredLanguage)
            if !zhResults.isEmpty { return zhResults }

            // If zh-CN returned nothing, try en-US
            if preferredLanguage.hasPrefix("zh") {
                let enResults = try await performSearch(title: query, type: type, key: effectiveKey, language: "en-US")
                if !enResults.isEmpty { return enResults }
            }

            // Also try cross-type search if series failed on tv or movie failed on movie
            let altType = (type == "tv") ? "movie" : "tv"
            let altResults = try await performSearch(title: query, type: altType, key: effectiveKey, language: preferredLanguage)
            if !altResults.isEmpty { return altResults }
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
