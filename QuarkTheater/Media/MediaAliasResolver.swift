import Foundation

/// Generates deterministic title variants without rewriting a canonical title into
/// an invalid substring (for example, 蜘蛛侠 must never become 蜘蛛侠侠).
enum MediaAliasResolver {
    static let builtInAliases: [(alias: String, canonical: String)] = [
        ("蛛丝", "蜘蛛侠"),
        ("蛛网", "蜘蛛侠"),
        ("高堡弃人", "高堡奇人"),
        ("使女", "使女的故事"),
        ("大西洋", "大西洋帝国"),
        ("绝命", "绝命毒师"),
        ("权游", "权力的游戏")
    ]

    static func normalizeTitle(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[._-]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func variants(for title: String, learnedAliases: [String: String] = [:]) -> [String] {
        let input = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var output: [String] = []
        var seen = Set<String>()
        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = normalizeTitle(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            output.append(trimmed)
        }
        append(input)

        let normalizedInput = normalizeTitle(input)
        let mappings = learnedAliases.map { (alias: $0.key, canonical: $0.value) }
            + builtInAliases
        for mapping in mappings.sorted(by: { normalizeTitle($0.alias) < normalizeTitle($1.alias) }) {
            let alias = normalizeTitle(mapping.alias)
            let canonical = mapping.canonical
            guard normalizedInput != normalizeTitle(canonical),
                  normalizedInput == alias || hasSafeSuffix(after: alias, in: normalizedInput) else { continue }
            append(replacePrefix(mapping.alias, with: canonical, in: input))
            append(canonical)
        }
        return output
    }

    private static func hasSafeSuffix(after alias: String, in value: String) -> Bool {
        guard value.hasPrefix(alias), value.count > alias.count else { return false }
        let suffix = String(value.dropFirst(alias.count))
        return suffix.first.map { $0.isNumber || $0.isWhitespace || ":：()[]".contains($0) } ?? false
    }

    private static func replacePrefix(_ alias: String, with canonical: String, in value: String) -> String {
        guard let range = value.range(of: alias, options: [.caseInsensitive, .diacriticInsensitive]) else { return canonical }
        return value.replacingCharacters(in: range, with: canonical)
    }
}
