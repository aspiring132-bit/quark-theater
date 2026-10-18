import Foundation

enum ParsedMediaUnresolvedReason: String, Equatable, Codable {
    case missingSeriesContext
}

struct ParsedMediaName: Equatable {
    let title: String
    let year: Int?
    let mediaType: MediaType
    let seasonNumber: Int?
    let episodeNumber: Int?
    /// If the title came from a parent folder rather than the filename itself, this is set.
    let inferredFromParent: Bool
    let unresolvedReason: ParsedMediaUnresolvedReason?

    init(title: String, year: Int? = nil, mediaType: MediaType, seasonNumber: Int? = nil, episodeNumber: Int? = nil, inferredFromParent: Bool = false, unresolvedReason: ParsedMediaUnresolvedReason? = nil) {
        self.title = title
        self.year = year
        self.mediaType = mediaType
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.inferredFromParent = inferredFromParent
        self.unresolvedReason = unresolvedReason
    }
}

enum FilenameParser {
    // MARK: - Episode patterns: SxxExx / xxXxx / 第X集 / bare numbers
    private static let episodePatterns = [
        #"(?i)^(.*?)(?:[ ._-]|\b)?[Ss](\d{1,2})\s*[Ee](\d{1,3})(?:[ ._-]|\b|$)"#,
        #"(?i)^(.*?)(?:[ ._-]|\b)?(\d{1,2})[xX](\d{1,3})(?:[ ._-]|\b|$)"#
    ]
    private static let chineseEpisodePattern = #"(?i)^(.*?)[ ._-]*第\s*(\d{1,3})\s*集"#
    // Bare or prefixed episode numbers: "01", "(09)", "9", "ep01", "E05", "0-1", "0-2", "01-02", "04_01"
    private static let bareNumberPattern = #"(?i)^(?:ep?|第)?[ ._-]?\(?(\d{1,3})\)?(?:集)?$"#
    private static let hyphenEpisodePattern = #"(?i)^(?:[Ss]?\d{1,2}[-_])(\d{1,3})$"#
    private static let yearPattern = #"(?:\(|\b)((?:19|20)\d{2})(?:\)|\b)"#
    private static let releaseTail = #"(?i)[ ._-]+(?:2160p|1080p|720p|480p|4k|8k|bluray|blu.?ray|web.?dl|webrip|hdtv|proper|remux|x26[45]|h\.?26[45]|hevc|avc|aac|dts).*$"#
    private static let strictSeasonPattern = #"(?i)^(?:s(?:eason)?\s*0?([0-9]{1,2})|第\s*([0-9]{1,2}|[一二三四五六七八九十]+)\s*季)$"#
    private static let genericFolders: Set<String> = [
        "extras", "specials", "featurettes", "trailers", "extra", "special",
        "影视", "电影", "电视剧", "tv", "movies", "shows", "series", "0"
    ]

    // MARK: - Public API

    /// Parse a filename, optionally using the folder hierarchy context.
    static func parse(
        _ filename: String,
        parentFolderName: String? = nil,
        detectedShowTitle: String? = nil,
        detectedSeasonNumber: Int? = nil
    ) -> ParsedMediaName {
        let base = (filename as NSString).deletingPathExtension

        // 1. Try SxxExx / xxXxx patterns
        for pattern in episodePatterns {
            if let match = firstMatch(pattern, in: base), match.numberOfRanges == 4,
               let season = Int(capture(match, 2, base)), let episode = Int(capture(match, 3, base)) {
                let rawTitle = capture(match, 1, base)
                let title = clean(rawTitle)
                // If title in filename is empty or just generic, fall back to detected show
                let effectiveTitle = !title.isEmpty ? title : (detectedShowTitle ?? folderTitle(parentFolderName) ?? filename)
                return ParsedMediaName(
                    title: effectiveTitle,
                    year: nil, mediaType: .series,
                    seasonNumber: season, episodeNumber: episode,
                    inferredFromParent: title.isEmpty && detectedShowTitle != nil
                )
            }
        }

        // 2. Try Chinese "第X集" pattern
        if let match = firstMatch(chineseEpisodePattern, in: base), match.numberOfRanges == 3,
           let episode = Int(capture(match, 2, base)) {
            let rawTitle = capture(match, 1, base)
            let title = clean(rawTitle)
            let effectiveTitle = !title.isEmpty ? title : (detectedShowTitle ?? folderTitle(parentFolderName) ?? filename)
            return ParsedMediaName(
                title: effectiveTitle,
                year: nil, mediaType: .series,
                seasonNumber: detectedSeasonNumber, episodeNumber: episode,
                inferredFromParent: title.isEmpty && detectedShowTitle != nil
            )
        }

        // 3. Bare or prefixed episode (e.g. "01.mp4", "(09)", "9", "ep01", "E05")
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        if let match = firstMatch(bareNumberPattern, in: trimmed),
           let episode = Int(capture(match, 1, trimmed)) {
            guard let effectiveTitle = detectedShowTitle ?? usableFolderTitle(parentFolderName) else {
                return unresolvedBareEpisode(episode: episode, season: detectedSeasonNumber)
            }
            return ParsedMediaName(
                title: effectiveTitle,
                year: nil, mediaType: .series,
                seasonNumber: detectedSeasonNumber, episodeNumber: episode,
                inferredFromParent: true
            )
        }

        // 4. Hyphenated episode (e.g. "0-1", "0-2", "04-01")
        if let match = firstMatch(hyphenEpisodePattern, in: trimmed),
           let episode = Int(capture(match, 1, trimmed)) {
            guard let effectiveTitle = detectedShowTitle ?? usableFolderTitle(parentFolderName) else {
                return unresolvedBareEpisode(episode: episode, season: detectedSeasonNumber)
            }
            return ParsedMediaName(
                title: effectiveTitle,
                year: nil, mediaType: .series,
                seasonNumber: detectedSeasonNumber, episodeNumber: episode,
                inferredFromParent: true
            )
        }

        // 5. Year-anchored movie
        let matchYear = firstMatch(yearPattern, in: base)
        let year = matchYear.flatMap { Int(capture($0, 1, base)) }
        let titleEnd = matchYear?.range.location ?? (base as NSString).length
        var title = (base as NSString).substring(to: titleEnd)
        title = title.replacingOccurrences(of: releaseTail, with: "", options: .regularExpression)
        title = clean(title)

        return ParsedMediaName(
            title: title.isEmpty ? (detectedShowTitle ?? base) : title,
            year: year, mediaType: detectedSeasonNumber != nil ? .series : .movie,
            seasonNumber: detectedSeasonNumber, episodeNumber: nil,
            inferredFromParent: false
        )
    }

    /// Parse a file with all known path context and an optional named bound root.
    static func parse(_ filename: String, pathComponents: [String], boundRootName: String?) -> ParsedMediaName {
        let context = extractShowAndSeason(fromPath: pathComponents, boundRootName: boundRootName)
        let parent = pathComponents.last
        return parse(filename, parentFolderName: parent, detectedShowTitle: context.show, detectedSeasonNumber: context.season)
    }

    // MARK: - Hierarchy Analysis

    /// Analyzes the full directory path array (e.g. ["来自：分享", "G 高堡奇人S01~S04", "Season 04", "S04"])
    /// and extracts (Show Title, Season Number).
    static func extractShowAndSeason(fromPath pathComponents: [String], boundRootName: String? = nil) -> (show: String?, season: Int?) {
        var season: Int? = nil
        var show: String? = nil

        for comp in pathComponents.reversed() {
            // Ignore top-level system drive tags
            if comp.contains("来自：") || comp.contains("网盘") || comp.contains("新建文件夹") {
                continue
            }

            // Only an entire component can be a season marker. A title containing S01 is not one.
            if season == nil {
                if let m = firstMatch(strictSeasonPattern, in: comp) {
                    let g1 = capture(m, 1, comp)
                    let g2 = capture(m, 2, comp)
                    if !g1.isEmpty, let num = Int(g1) {
                        season = num
                    } else if !g2.isEmpty, let num = parseChineseSeasonNumber(g2) {
                        season = num
                    }
                }
            }

            if show == nil, let ft = usableFolderTitle(comp) {
                show = ft
            }
        }

        // A bound root is only a fallback.  A nearer named folder (for example
        // root/category/show/S01) carries more specific context and must win.
        if show == nil, let boundRootName, let rootTitle = usableFolderTitle(boundRootName) {
            show = rootTitle
        }
        return (show, season)
    }

    private static func parseChineseSeasonNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let num = Int(trimmed) { return num }
        let chineseDigits: [String: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
            "十一": 11, "十二": 12, "十三": 13, "十四": 14, "十五": 15,
            "十六": 16, "十七": 17, "十八": 18, "十九": 19, "二十": 20
        ]
        return chineseDigits[trimmed]
    }

    private static func unresolvedBareEpisode(episode: Int, season: Int?) -> ParsedMediaName {
        ParsedMediaName(
            title: "", year: nil, mediaType: .unknown,
            seasonNumber: season, episodeNumber: episode,
            inferredFromParent: true, unresolvedReason: .missingSeriesContext
        )
    }

    private static func usableFolderTitle(_ folderName: String?) -> String? {
        guard let title = folderTitle(folderName), !genericFolders.contains(title.lowercased()) else { return nil }
        return title
    }

    /// Extract a human-readable show title from a folder name, stripping season markers,
    /// site prefixes ("G 高堡奇人", "S使女的故事"), trailing counts, and resolution tags.
    static func folderTitle(_ folderName: String?) -> String? {
        guard let folderName else { return nil }
        var s = folderName
        // Normalize censorship or typo bypass patterns like "挽救#J划" -> "挽救计划"
        s = s.replacingOccurrences(of: #"#\s*[jJ]?"#, with: "计", options: .regularExpression)
        // Strip bracketed prefixes like "【美剧】", "[日剧]", "[4K]"
        s = s.replacingOccurrences(of: #"^[【\[][^】\]]+[】\]]\s*"#, with: "", options: .regularExpression)
        // Strip single letter share-site / sorting prefixes:
        // E.g. "G 高堡奇人", "S使女的故事" (with or without space, immediately before Chinese character)
        s = s.replacingOccurrences(of: #"^[A-Za-z]\s*(?=[\u4e00-\u9fa5])"#, with: "", options: .regularExpression)
        // Also strip single letter + whitespace if followed by ASCII
        s = s.replacingOccurrences(of: #"^[A-Za-z]\s+"#, with: "", options: .regularExpression)
        // Strip season indicators like "S01~S04", "S01-S04", "S01", "第1季", "第四季", "Season 1", "全5季", "全6部"
        s = s.replacingOccurrences(of: #"(?i)^[Ss]\d{1,2}(?:\s*[~-]\s*[Ss]?\d{1,2})?$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)[\s._-]+[Ss]\d{1,2}(?:\s*[~-]\s*[Ss]?\d{1,2})?.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*第\s*(?:\d+|[一二三四五六七八九十]+)\s*季.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*全\s*(?:\d+|[一二三四五六七八九十]+)\s*[季部集].*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\s*Season\s*(?:\d+|[一二三四五六七八九十]+).*$"#, with: "", options: .regularExpression)
        // Strip trailing episode counts "(1)", "(2)", "(全23集)"
        s = s.replacingOccurrences(of: #"\s*[\(（]\s*\d+\s*[\)）]$"#, with: "", options: .regularExpression)
        // Strip resolution & encoding tags
        s = s.replacingOccurrences(of: #"(?i)\b(2160p|1080p|720p|4k|web-dl|webrip|x264|x265|h264|h265|aac|chs|eng).*\b"#, with: "", options: .regularExpression)
        // Clean dots and underscores
        s = s.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]【】（）()「」"))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func firstMatch(_ pattern: String, in value: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }
    private static func capture(_ match: NSTextCheckingResult, _ index: Int, _ value: String) -> String {
        guard let range = Range(match.range(at: index), in: value) else { return "" }
        return String(value[range])
    }
    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
