import Foundation
import ASTRACore

struct FeedbackSanitizationResult: Equatable, Sendable {
    let text: String
    let redaction: FeedbackRedactionSummaryV1
    let wasTruncated: Bool
}

enum FeedbackEvidenceSanitizer {
    private struct Rule {
        enum Category {
            case secret
            case path
            case contact
        }

        let pattern: String
        let replacement: String
        let category: Category
        let options: NSRegularExpression.Options
    }

    private static let rules: [Rule] = [
        Rule(
            pattern: #"(?i)\bhttps?://[^/\s:@]+:[^@\s]+@[^\s]+"#,
            replacement: "[redacted-url]",
            category: .secret,
            options: []
        ),
        Rule(
            pattern: #"(?i)(authorization|bearer|token|api[_-]?key|secret|password|credential)\s*[:=]\s*['\"]?[^'\"\s,;)]+"#,
            replacement: "$1=[redacted-secret]",
            category: .secret,
            options: []
        ),
        Rule(
            pattern: #"(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{16})\b"#,
            replacement: "[redacted-secret]",
            category: .secret,
            options: []
        ),
        Rule(
            pattern: #"-----BEGIN [^-\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\n]*PRIVATE KEY-----"#,
            replacement: "[redacted-private-key]",
            category: .secret,
            options: [.caseInsensitive]
        ),
        Rule(
            pattern: #"\b[A-Fa-f0-9]{32,}\b|\b[A-Za-z0-9_-]{40,}\b"#,
            replacement: "[redacted-token]",
            category: .secret,
            options: []
        ),
        Rule(
            pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            replacement: "[redacted-email]",
            category: .contact,
            options: []
        ),
        Rule(
            pattern: #"(?<![A-Za-z0-9])(?:\+?1[ .-]?)?\(?[2-9][0-9]{2}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}(?![A-Za-z0-9])"#,
            replacement: "[redacted-phone]",
            category: .contact,
            options: []
        ),
        Rule(
            pattern: #"(?:file://)?/Users/[^\s\"']+"#,
            replacement: "[redacted-home-path]",
            category: .path,
            options: []
        ),
        Rule(
            pattern: #"(?<![A-Za-z0-9_])(?:/[A-Za-z0-9._ -]+){2,}"#,
            replacement: "[redacted-path]",
            category: .path,
            options: []
        )
    ]

    static func sanitize(_ value: String, maximumBytes: Int) -> FeedbackSanitizationResult {
        var output = FeedbackContractNormalizationV1.text(value)
        var secretPatterns = 0
        var pathPatterns = 0
        var contactPatterns = 0

        for rule in rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = expression.numberOfMatches(in: output, range: range)
            guard matches > 0 else { continue }
            output = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: rule.replacement
            )
            switch rule.category {
            case .secret: secretPatterns += matches
            case .path: pathPatterns += matches
            case .contact: contactPatterns += matches
            }
        }

        let bounded = boundedUTF8(output, maximumBytes: maximumBytes)
        return FeedbackSanitizationResult(
            text: bounded.text,
            redaction: FeedbackRedactionSummaryV1(
                replacements: secretPatterns + pathPatterns + contactPatterns,
                secretPatterns: secretPatterns,
                pathPatterns: pathPatterns,
                contactPatterns: contactPatterns
            ),
            wasTruncated: bounded.wasTruncated
        )
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> (text: String, wasTruncated: Bool) {
        guard value.utf8.count > maximumBytes else { return (value, false) }
        let suffix = "\n[truncated]"
        let budget = max(0, maximumBytes - suffix.utf8.count)
        var bytes = 0
        var end = value.startIndex
        for index in value.indices {
            let next = value.index(after: index)
            let scalarBytes = value[index..<next].utf8.count
            guard bytes + scalarBytes <= budget else { break }
            bytes += scalarBytes
            end = next
        }
        return (String(value[..<end]) + suffix, true)
    }
}
