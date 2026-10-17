import Foundation

struct ParsedMediaName: Equatable {
    let title: String
    let year: Int?
    let mediaType: MediaType
    let seasonNumber: Int?
    let episodeNumber: Int?
}

enum FilenameParser {
    private static let episodePatterns = [
        #"(?i)^(.*?)\bS(\d{1,2})\s*E(\d{1,3})\b"#,
        #"(?i)^(.*?)\b(\d{1,2})x(\d{1,3})\b"#
    ]
    private static let yearPattern = #"(?:\(|\b)((?:19|20)\d{2})(?:\)|\b)"#
    private static let releaseTail = #"(?i)[ ._-]+(?:2160p|1080p|720p|480p|4k|8k|bluray|blu.?ray|web.?dl|webrip|hdtv|proper|remux|x26[45]|h\.?26[45]|hevc|avc|aac|dts).*$"#

    static func parse(_ filename: String) -> ParsedMediaName {
        let base = (filename as NSString).deletingPathExtension
        for pattern in episodePatterns {
            if let match = firstMatch(pattern, in: base), match.numberOfRanges == 4,
               let season = Int(capture(match, 2, base)), let episode = Int(capture(match, 3, base)) {
                return ParsedMediaName(title: clean(capture(match, 1, base)), year: nil,
                    mediaType: .series, seasonNumber: season, episodeNumber: episode)
            }
        }
        let match = firstMatch(yearPattern, in: base)
        let year = match.flatMap { Int(capture($0, 1, base)) }
        let titleEnd = match?.range.location ?? (base as NSString).length
        var title = (base as NSString).substring(to: titleEnd)
        title = title.replacingOccurrences(of: releaseTail, with: "", options: .regularExpression)
        return ParsedMediaName(title: clean(title), year: year, mediaType: .movie,
                               seasonNumber: nil, episodeNumber: nil)
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
