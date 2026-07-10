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

        let expression: NSRegularExpression
        let replacement: String
        let category: Category

        init(pattern: String, replacement: String, category: Category, options: NSRegularExpression.Options) {
            // Patterns are fixed string literals below; compilation cannot fail at runtime.
            // swiftlint:disable:next force_try
            self.expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.replacement = replacement
            self.category = category
        }
    }

    // Rules shared between free-form text sanitization and URL path sanitization.
    // None of these assume filesystem-path shape, so they are safe to run against a
    // URL path component (e.g. a browser evidence route) without mistaking an
    // ordinary multi-segment route for a local file path.
    private static let sharedRules: [Rule] = [
        Rule(
            pattern: #"(?i)\bhttps?://[^/\s:@]+:[^@\s]+@[^\s]+"#,
            replacement: "[redacted-url]",
            category: .secret,
            options: []
        ),
        Rule(
            pattern: #"(?im)\bauthorization\s*[:=]\s*['\"]?[^\r\n'\"]+['\"]?"#,
            replacement: "authorization=[redacted-secret]",
            category: .secret,
            options: []
        ),
        Rule(
            pattern: #"(?i)\b(?:basic|bearer)\s+[A-Za-z0-9+/=_~.-]+"#,
            replacement: "[redacted-secret]",
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
            // Includes bare Google API keys (AIza + 35 chars = 39 total), which are
            // one character short of the generic 40+ char fallback below and would
            // otherwise survive sanitization when not emitted as `api_key=...`.
            pattern: #"(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})\b"#,
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
            // A terminal file extension provides a safe boundary for filenames that
            // themselves contain spaces. Stop at that boundary so trailing log prose
            // survives while the complete private path is removed.
            pattern: #"(?:file://)?/Users/[^\s/\"']+(?:/[^/\"'\r\n]+)*?\.[A-Za-z0-9]{1,16}(?=$|[\s,;:)\]])"#,
            replacement: "[redacted-home-path]",
            category: .path,
            options: []
        ),
        Rule(
            // A space is unambiguously part of an unquoted path component when that
            // component is followed by another slash. Permit any whitespace run in
            // those directory components, but keep the terminal component bounded by
            // whitespace so ordinary log prose after the path remains diagnostic.
            pattern: #"(?:file://)?/Users/[^\s/\"']+(?:/[^/\"'\r\n]+(?=/))*(?:/[^\s/\"']+)?"#,
            replacement: "[redacted-home-path]",
            category: .path,
            options: []
        )
    ]

    // Matches a generic local-filesystem path by its multi-segment shape. This is a
    // reasonable heuristic for free-form log/text content, but it also matches an
    // ordinary URL route (e.g. "/issues/123"), so it must NOT be applied when
    // sanitizing a URL path field — use sanitizeURLPath for that instead.
    private static let genericFilesystemFileRule = Rule(
        pattern: #"(?<![A-Za-z0-9_])(?:/[^/\"'\r\n]+){2,}?\.[A-Za-z0-9]{1,16}(?=$|[\s,;:)\]])"#,
        replacement: "[redacted-path]",
        category: .path,
        options: []
    )

    private static let genericFilesystemPathRule = Rule(
        // Require at least one directory component followed by a slash, then a
        // whitespace-bounded terminal component. This consumes punctuated or
        // repeated-space directory names without swallowing unrelated prose after the
        // terminal path component.
        pattern: #"(?<![A-Za-z0-9_])(?:/[^/\"'\r\n]+(?=/)){1,}(?:/[^\s/\"']+)"#,
        replacement: "[redacted-path]",
        category: .path,
        options: []
    )

    private static let rules: [Rule] = sharedRules + [genericFilesystemFileRule, genericFilesystemPathRule]

    // Rule set for sanitizing a URL path component (e.g. a browser evidence route).
    // Excludes genericFilesystemPathRule, whose local-file path heuristic matches any
    // route with two or more segments and would redact the whole route, stripping the
    // screen/route context that diagnostics need.
    private static let urlPathRules: [Rule] = sharedRules

    static func sanitize(_ value: String, maximumBytes: Int) -> FeedbackSanitizationResult {
        apply(rules, to: value, maximumBytes: maximumBytes)
    }

    /// Sanitizes a URL path component (query/fragment already stripped by the caller)
    /// without applying the generic local-filesystem-path rule, so an ordinary
    /// multi-segment route survives while secrets, tokens, and contact values embedded
    /// in the path are still redacted.
    static func sanitizeURLPath(_ value: String, maximumBytes: Int) -> FeedbackSanitizationResult {
        apply(urlPathRules, to: value, maximumBytes: maximumBytes)
    }

    private static func apply(_ ruleSet: [Rule], to value: String, maximumBytes: Int) -> FeedbackSanitizationResult {
        var output = FeedbackContractNormalizationV1.text(value)
        var secretPatterns = 0
        var pathPatterns = 0
        var contactPatterns = 0

        for rule in ruleSet {
            let expression = rule.expression
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
