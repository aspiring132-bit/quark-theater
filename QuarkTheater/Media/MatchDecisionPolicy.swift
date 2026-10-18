import Foundation

enum MatchDisposition: Equatable {
    case autoConfirm(ScoredTMDBResult)
    case needsUserConfirmation(candidates: [ScoredTMDBResult], reason: String)
    case unmatched(reason: String)

    var isAutoConfirmed: Bool {
        if case .autoConfirm = self { return true }
        return false
    }

    var bestResult: ScoredTMDBResult? {
        switch self {
        case .autoConfirm(let best):
            return best
        case .needsUserConfirmation(let candidates, _):
            return candidates.first
        case .unmatched:
            return nil
        }
    }
}

enum MatchDecisionPolicy {
    static let autoConfirmThreshold: Double = 0.95
    static let manualConfirmationThreshold: Double = 0.82
    static let minimumMargin: Double = 0.05

    /// Centralized decision engine for candidate match disposition.
    static func evaluate(_ ranked: [ScoredTMDBResult], parsed: ParsedMediaName? = nil) -> MatchDisposition {
        guard let first = ranked.first else {
            return .unmatched(reason: "未在 TMDB 检索到相关影视条目")
        }

        // Low confidence: leave as unmatched, do not guess
        if first.confidence < manualConfirmationThreshold {
            return .unmatched(reason: "匹配置信度过低 (\(Int(first.confidence * 100))%)，保留在待匹配列表")
        }

        // High confidence check with separation margin against runner-up
        if first.confidence >= autoConfirmThreshold {
            if let second = ranked.dropFirst().first {
                let margin = first.confidence - second.confidence
                if margin >= minimumMargin {
                    return .autoConfirm(first)
                } else {
                    return .needsUserConfirmation(
                        candidates: ranked,
                        reason: "首选条目与次选项置信度相近 (差距仅 \(Int(margin * 100))%)，请人工核对"
                    )
                }
            } else {
                return .autoConfirm(first)
            }
        }

        // Middle confidence [0.82, 0.95): requires explicit user confirmation
        return .needsUserConfirmation(
            candidates: ranked,
            reason: "匹配置信度为 \(Int(first.confidence * 100))%，属于可信候选，请人工确认入库"
        )
    }
}
