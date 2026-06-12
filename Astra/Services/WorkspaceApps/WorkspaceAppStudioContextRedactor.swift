import Foundation

enum WorkspaceAppStudioContextRedactor {
    private struct Rule {
        var pattern: String
        var replacement: String
    }

    private static let rules: [Rule] = [
        Rule(
            pattern: #"(?i)("(?:apiKey|api_key|token|secret|password)"\s*:\s*")[^"]+(")"#,
            replacement: #"$1[redacted]$2"#
        ),
        Rule(
            pattern: #"(?i)(\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|APIKEY)[A-Z0-9_]*\s*=\s*)[^\s,;}]+"#,
            replacement: "$1[redacted]"
        ),
        Rule(
            pattern: #"(?i)(\b(?:api[_ -]?key|token|secret|password)\b\s*[:=]\s*)[^\s,;}"]+"#,
            replacement: "$1[redacted]"
        ),
        Rule(
            pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}\b"#,
            replacement: "bearer [redacted]"
        ),
        Rule(
            pattern: #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
            replacement: "[redacted]"
        ),
        Rule(
            pattern: #"\bgh[opsru]_[A-Za-z0-9_]{8,}\b"#,
            replacement: "[redacted]"
        ),
        Rule(
            pattern: #"\bxox[baprs]-[A-Za-z0-9-]{8,}\b"#,
            replacement: "[redacted]"
        )
    ]

    static func redact(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        return rules.reduce(trimmed) { current, rule in
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern,
                options: []
            ) else {
                return current
            }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
    }
}
