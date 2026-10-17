import Foundation

struct ScoredTMDBResult: Equatable {
    let result: TMDBSearchResult
    let confidence: Double
    var requiresManualConfirmation: Bool { confidence < 0.82 }
}

enum MediaMatchScorer {
    /// Conservative title/year score for ranking suggestions only. It never writes a match.
    static func rank(_ results: [TMDBSearchResult], for parsed: ParsedMediaName) -> [ScoredTMDBResult] {
        results.map { result in
            let candidate = normalize(result.displayTitle)
            let source = normalize(parsed.title)
            let titleScore: Double
            if candidate == source { titleScore = 0.78 }
            else {
                let a = Set(candidate.split(separator: " "))
                let b = Set(source.split(separator: " "))
                let union = a.union(b).count
                titleScore = union == 0 ? 0 : 0.70 * Double(a.intersection(b).count) / Double(union)
            }
            let yearAdjustment: Double
            if let requested = parsed.year, let candidateYear = result.year {
                yearAdjustment = requested == candidateYear ? 0.20 : -0.20
            } else { yearAdjustment = 0 }
            return ScoredTMDBResult(result: result, confidence: min(1, max(0, titleScore + yearAdjustment)))
        }.sorted {
            if $0.confidence == $1.confidence { return $0.result.id < $1.result.id }
            return $0.confidence > $1.confidence
        }
    }

    static func mayAutoConfirm(_ match: ScoredTMDBResult) -> Bool { match.confidence >= 0.95 }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
