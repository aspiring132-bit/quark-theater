import Foundation

struct ScoredTMDBResult: Equatable {
    let result: TMDBSearchResult
    let confidence: Double
    var requiresManualConfirmation: Bool { confidence < 0.82 }
}

enum MediaMatchScorer {
    static func rank(
        _ results: [TMDBSearchResult],
        for parsed: ParsedMediaName,
        ancestorFolderName: String? = nil
    ) -> [ScoredTMDBResult] {
        results.map { result in
            let candidateDisplay = normalize(result.displayTitle)
            let candidateOriginal = normalize(result.effectiveOriginalTitle)
            let source = normalize(parsed.title)
            let ancestor = ancestorFolderName.map(normalize) ?? ""

            var titleScore: Double = 0
            if candidateDisplay == source || candidateOriginal == source {
                titleScore = 0.85
            } else if !ancestor.isEmpty && (candidateDisplay == ancestor || candidateOriginal == ancestor) {
                titleScore = 0.82
            } else {
                let sWords = Set(source.split(separator: " "))
                let dWords = Set(candidateDisplay.split(separator: " "))
                let oWords = Set(candidateOriginal.split(separator: " "))

                let dUnion = sWords.union(dWords).count
                let dScore = dUnion == 0 ? 0 : 0.70 * Double(sWords.intersection(dWords).count) / Double(dUnion)

                let oUnion = sWords.union(oWords).count
                let oScore = oUnion == 0 ? 0 : 0.70 * Double(sWords.intersection(oWords).count) / Double(oUnion)

                titleScore = max(dScore, oScore)
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
