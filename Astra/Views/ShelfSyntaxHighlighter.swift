import AppKit

enum ShelfSyntaxHighlighter {
    static let maxHighlightedUTF8Bytes = 256 * 1_024

    static func attributedString(for text: String, language: ShelfSyntaxLanguage) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: baseAttributes
        )
        guard !text.isEmpty else { return attributed }
        // Avoid running regex highlighters over large files during SwiftUI view updates.
        guard text.utf8.count <= maxHighlightedUTF8Bytes else { return attributed }

        switch language {
        case .json:
            highlightJSON(in: attributed, text: text)
        case .swift:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
                    "class", "continue", "default", "defer", "do", "else", "enum", "extension",
                    "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil",
                    "private", "protocol", "public", "return", "self", "static", "struct",
                    "switch", "throw", "throws", "true", "try", "var", "where", "while"
                ],
                lineCommentPattern: #"//[^\n\r]*"#,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .javascript, .typescript:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "async", "await", "break", "case", "catch", "class", "const", "continue",
                    "default", "delete", "else", "export", "extends", "false", "finally",
                    "for", "from", "function", "if", "import", "in", "instanceof", "interface",
                    "let", "new", "null", "return", "switch", "this", "throw", "true", "try",
                    "type", "typeof", "undefined", "var", "void", "while", "yield"
                ],
                lineCommentPattern: #"//[^\n\r]*"#,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .html:
            apply(pattern: #"<!--[\s\S]*?-->"#, color: .secondaryLabelColor, to: attributed, options: [.dotMatchesLineSeparators])
            apply(pattern: #"</?[A-Za-z][^>\s/]*"#, color: .systemBlue, to: attributed)
            apply(pattern: #"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\=)"#, color: .systemPurple, to: attributed)
            highlightStrings(in: attributed)
        case .css:
            apply(pattern: #"#[0-9A-Fa-f]{3,8}\b"#, color: .systemPink, to: attributed)
            apply(pattern: #"\b-?\d+(?:\.\d+)?(?:px|rem|em|vh|vw|%|s|ms)?\b"#, color: .systemOrange, to: attributed)
            highlightCode(
                in: attributed,
                text: text,
                keywords: ["important", "media", "supports", "keyframes", "from", "to"],
                lineCommentPattern: nil,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .python:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "and", "as", "assert", "async", "await", "break", "class", "continue",
                    "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
                    "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
                    "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
                ],
                lineCommentPattern: "#[^\\n\\r]*",
                blockCommentPattern: nil
            )
        case .shell:
            apply(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#, color: .systemPurple, to: attributed)
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "case", "cd", "done", "do", "elif", "else", "esac", "fi", "for", "function",
                    "if", "in", "then", "while"
                ],
                lineCommentPattern: "#[^\\n\\r]*",
                blockCommentPattern: nil
            )
        case .sql:
            highlightCode(
                in: attributed,
                text: text,
                keywords: [
                    "ALTER", "AND", "AS", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DROP",
                    "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INSERT", "INTO", "IS",
                    "JOIN", "LEFT", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER",
                    "RIGHT", "SELECT", "SET", "TABLE", "THEN", "UNION", "UPDATE", "VALUES",
                    "WHEN", "WHERE", "WITH"
                ],
                lineCommentPattern: #"--[^\n\r]*"#,
                blockCommentPattern: #"/\*[\s\S]*?\*/"#
            )
        case .yaml:
            apply(pattern: "#[^\\n\\r]*", color: .secondaryLabelColor, to: attributed, options: [.anchorsMatchLines])
            apply(pattern: #"^\s*[-A-Za-z0-9_.]+(?=\s*:)"#, color: .systemBlue, to: attributed, options: [.anchorsMatchLines])
            apply(pattern: #"\b(true|false|null|yes|no|on|off)\b"#, color: .systemPurple, to: attributed, options: [.caseInsensitive])
            apply(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: .systemOrange, to: attributed)
            highlightStrings(in: attributed)
        case .markdown:
            apply(pattern: #"^#{1,6}\s+.*$"#, color: .systemBlue, to: attributed, options: [.anchorsMatchLines])
            apply(pattern: #"`[^`\n]+`"#, color: .systemOrange, to: attributed)
            apply(pattern: #"```[\s\S]*?```"#, color: .systemGreen, to: attributed, options: [.dotMatchesLineSeparators])
            apply(pattern: #"\*\*[^*\n]+\*\*"#, color: .systemPurple, to: attributed)
            apply(pattern: #"^\s*[-*+]\s+"#, color: .systemBlue, to: attributed, options: [.anchorsMatchLines])
        case .plaintext:
            break
        }

        return attributed
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static func highlightJSON(in attributed: NSMutableAttributedString, text: String) {
        apply(pattern: #"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, to: attributed)
        apply(pattern: #"\b(true|false|null)\b"#, color: .systemPurple, to: attributed)
        apply(pattern: #""(?:\\.|[^"\\])*""#, color: .systemGreen, to: attributed)
        apply(pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#, color: .systemBlue, to: attributed)
    }

    private static func highlightCode(
        in attributed: NSMutableAttributedString,
        text: String,
        keywords: [String],
        lineCommentPattern: String?,
        blockCommentPattern: String?
    ) {
        apply(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: .systemOrange, to: attributed)
        applyKeywords(keywords, color: .systemBlue, to: attributed)
        let stringRanges = highlightStrings(in: attributed)
        if let blockCommentPattern {
            apply(
                pattern: blockCommentPattern,
                color: .secondaryLabelColor,
                to: attributed,
                options: [.dotMatchesLineSeparators],
                excludingMatchStartsIn: stringRanges
            )
        }
        if let lineCommentPattern {
            apply(
                pattern: lineCommentPattern,
                color: .secondaryLabelColor,
                to: attributed,
                options: [.anchorsMatchLines],
                excludingMatchStartsIn: stringRanges
            )
        }
    }

    @discardableResult
    private static func highlightStrings(in attributed: NSMutableAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges += apply(pattern: #""(?:\\.|[^"\\])*""#, color: .systemGreen, to: attributed)
        ranges += apply(pattern: #"'(?:\\.|[^'\\])*'"#, color: .systemGreen, to: attributed)
        return ranges
    }

    private static func applyKeywords(
        _ keywords: [String],
        color: NSColor,
        to attributed: NSMutableAttributedString
    ) {
        let pattern = "\\b(\(keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")))\\b"
        apply(pattern: pattern, color: color, to: attributed, options: [.caseInsensitive])
    }

    @discardableResult
    private static func apply(
        pattern: String,
        color: NSColor,
        to attributed: NSMutableAttributedString,
        options: NSRegularExpression.Options = [],
        excludingMatchStartsIn excludedRanges: [NSRange] = []
    ) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        var appliedRanges: [NSRange] = []
        let range = NSRange(location: 0, length: attributed.length)
        regex.enumerateMatches(in: attributed.string, range: range) { match, _, _ in
            guard let matchRange = match?.range, matchRange.location != NSNotFound else { return }
            let startsInExcludedRange = excludedRanges.contains { excludedRange in
                NSLocationInRange(matchRange.location, excludedRange)
            }
            guard !startsInExcludedRange else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: matchRange)
            appliedRanges.append(matchRange)
        }
        return appliedRanges
    }
}
