import Foundation

enum LogSanitizer {
    static func sanitizeURLString(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else {
            return urlString
        }
        var sanitizedComponents = components
        if sanitizedComponents.queryItems != nil {
            sanitizedComponents.queryItems = [URLQueryItem(name: "params", value: "[REDACTED]")]
        }
        return sanitizedComponents.string ?? urlString
    }

    static func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        var result = headers
        let sensitiveKeys = ["authorization", "cookie", "set-cookie", "token", "x-token", "auth-token"]
        for key in result.keys {
            if sensitiveKeys.contains(key.lowercased()) {
                result[key] = "[REDACTED]"
            }
        }
        return result
    }

    static func sanitize(_ text: String) -> String {
        var result = text
        // Redact patterns like token=xyz, password=xyz, cookie=xyz, key=xyz
        let patterns = [
            #"(token=)[^&\s]+"#,
            #"(password=)[^&\s]+"#,
            #"(p_skey=)[^;&\s]+"#,
            #"(cookie:\s*)[^\n]+"#,
            #"(auth_key=)[^&\s]+"#,
            #"(secret=)[^&\s]+"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1[REDACTED]")
            }
        }
        return result
    }
}
