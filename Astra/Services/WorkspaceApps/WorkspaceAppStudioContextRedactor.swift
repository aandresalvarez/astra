import Foundation

enum WorkspaceAppStudioContextRedactor {
    private struct Rule {
        let pattern: String
        let replacement: String
    }

    private struct CompiledRule {
        let regex: NSRegularExpression
        let replacement: String
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

    private static let compiledRules: [CompiledRule] = rules.map { rule in
        do {
            return CompiledRule(
                regex: try NSRegularExpression(pattern: rule.pattern, options: []),
                replacement: rule.replacement
            )
        } catch {
            preconditionFailure("Invalid Workspace App Studio redaction pattern '\(rule.pattern)': \(error)")
        }
    }

    static func redact(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        return compiledRules.reduce(trimmed) { current, rule in
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return rule.regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
    }
}
