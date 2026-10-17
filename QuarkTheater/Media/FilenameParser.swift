import Foundation

struct ParsedMediaName: Equatable {
    let title: String
    let year: Int?
    let mediaType: MediaType
    let seasonNumber: Int?
    let episodeNumber: Int?
    /// If the title came from a parent folder rather than the filename itself, this is set.
    let inferredFromParent: Bool
}

enum FilenameParser {
    // MARK: - Episode patterns: SxxExx / xxXxx / bare numbers
    private static let episodePatterns = [
        #"(?i)^(.*?)\bS(\d{1,2})\s*E(\d{1,3})\b"#,
        #"(?i)^(.*?)\b(\d{1,2})x(\d{1,3})\b"#
    ]
    // Bare bare-number episode: file is just "01", "(09)", "第3集" etc. — no title info at all.
    private static let bareNumberPattern = #"^\(?(\d{1,3})\)?$"#
    private static let yearPattern = #"(?:\(|\b)((?:19|20)\d{2})(?:\)|\b)"#
    private static let releaseTail = #"(?i)[ ._-]+(?:2160p|1080p|720p|480p|4k|8k|bluray|blu.?ray|web.?dl|webrip|hdtv|proper|remux|x26[45]|h\.?26[45]|hevc|avc|aac|dts).*$"#

    // MARK: - Public API

    /// Parse a filename, optionally using the parent folder name as a context hint.
    /// - Parameters:
    ///   - filename: The raw file name (with or without extension).
    ///   - parentFolderName: The immediate parent folder name; used when the filename
    ///     carries no title information (bare episode numbers, S01/S02 labels, etc.).
    static func parse(_ filename: String, parentFolderName: String? = nil) -> ParsedMediaName {
        let base = (filename as NSString).deletingPathExtension

        // 1. Try SxxExx / xxXxx patterns
        for pattern in episodePatterns {
            if let match = firstMatch(pattern, in: base), match.numberOfRanges == 4,
               let season = Int(capture(match, 2, base)), let episode = Int(capture(match, 3, base)) {
                let rawTitle = capture(match, 1, base)
                let title = clean(rawTitle)
                // If the embedded title is empty/whitespace, fall back to parent folder
                let finalTitle = title.isEmpty ? folderTitle(parentFolderName) ?? title : title
                return ParsedMediaName(
                    title: finalTitle.isEmpty ? (parentFolderName ?? filename) : finalTitle,
                    year: nil, mediaType: .series,
                    seasonNumber: season, episodeNumber: episode,
                    inferredFromParent: title.isEmpty && parentFolderName != nil
                )
            }
        }

        // 2. Bare number episode (e.g. "01.mp4", "(09)", "9")
        if let match = firstMatch(bareNumberPattern, in: base.trimmingCharacters(in: .whitespaces)),
           let episode = Int(capture(match, 1, base.trimmingCharacters(in: .whitespaces))) {
            // We need the parent folder to figure out which show this belongs to.
            // Heuristic: derive season from grandparent-like clues in parentFolderName ("S04", "第4季").
            let (parentTitle, parentSeason) = parseFolderForSeason(parentFolderName)
            return ParsedMediaName(
                title: parentTitle ?? (parentFolderName ?? base),
                year: nil, mediaType: .series,
                seasonNumber: parentSeason, episodeNumber: episode,
                inferredFromParent: true
            )
        }

        // 3. Year-anchored movie
        let matchYear = firstMatch(yearPattern, in: base)
        let year = matchYear.flatMap { Int(capture($0, 1, base)) }
        let titleEnd = matchYear?.range.location ?? (base as NSString).length
        var title = (base as NSString).substring(to: titleEnd)
        title = title.replacingOccurrences(of: releaseTail, with: "", options: .regularExpression)
        title = clean(title)

        // 4. Strip subtitle-only suffix after Chinese colon (：) if the prefix looks like a transliterated title
        //    e.g. "蛛丝4：焕然一新" → use "蛛丝4" for search, which TMDB won't find; better to search the raw name
        //    and also attempt stripping the suffix.
        //    We keep both title and stripped variant; the scorer will pick the better match.

        return ParsedMediaName(
            title: title.isEmpty ? base : title,
            year: year, mediaType: .movie,
            seasonNumber: nil, episodeNumber: nil,
            inferredFromParent: false
        )
    }

    // MARK: - Helpers

    /// Extract a human-readable show title from a parent folder name, stripping season markers
    /// like "S01", "第1季", "Season 1", trailing series counts, brackets etc.
    static func folderTitle(_ folderName: String?) -> String? {
        guard let folderName else { return nil }
        var s = folderName
        // Strip leading single-letter prefixes used by some share sites ("G 高堡奇人", "S使女的故事")
        s = s.replacingOccurrences(of: #"^[A-Za-z]\s+"#, with: "", options: .regularExpression)
        // Strip season markers: S01~S04, S01, 第X季, Season X
        s = s.replacingOccurrences(of: #"\s*[Ss]\d{1,2}(?:~[Ss]\d{1,2})?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*第\d+季"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\s*[Ss]eason\s*\d+"#, with: "", options: .regularExpression)
        // Strip trailing episode counts "(1)", "全23集", etc.
        s = s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*全\d+[集部].*$"#, with: "", options: .regularExpression)
        // Strip leading/trailing brackets
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]【】（）()「」"))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Parse a season folder name like "S01", "S04", "第2季" and return (cleaned show title if any, season number).
    private static func parseFolderForSeason(_ folderName: String?) -> (String?, Int?) {
        guard let folderName else { return (nil, nil) }
        // Pure season label: "S01", "S04", "Season 2", "第3季"
        if let m = firstMatch(#"^[Ss](?:eason\s*)?(\d{1,2})$"#, in: folderName.trimmingCharacters(in: .whitespaces)),
           let season = Int(capture(m, 1, folderName)) {
            return (nil, season)
        }
        if let m = firstMatch(#"^第(\d+)季$"#, in: folderName.trimmingCharacters(in: .whitespaces)),
           let season = Int(capture(m, 1, folderName)) {
            return (nil, season)
        }
        return (folderTitle(folderName), nil)
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
