import Foundation

/// Tokenizes raw Markdown source for in-place syntax highlighting in an
/// editable text view — NOT a renderer. Markers (`#`, `**`, `` ` ``, `[]()`)
/// stay in the text and get their own dimmed token so the user keeps editing
/// literal Markdown; only the *styling* changes, mirroring how
/// `SQLSyntaxTokenizer` colors SQL source without rewriting it. Line-based
/// and single-pass: good enough to make a hand-typed prompt readable at a
/// glance, not a spec-complete CommonMark parser (no nested emphasis, no
/// reference-style links).
enum MarkdownSourceSyntaxTokenizer {
    struct Token: Equatable {
        let range: NSRange
        let kind: Kind
    }

    enum Kind: Equatable {
        case headingMarker
        case heading(level: Int)
        case listMarker
        case blockquoteMarker
        case divider
        case codeFenceMarker
        case codeBlockLine
        case codeSpanMarker
        case codeSpan
        case emphasisMarker
        case bold
        case italic
        case strikethrough
        case linkBracket
        case linkLabel
        case linkURL
    }

    static func tokens(in text: String) -> [Token] {
        guard !text.isEmpty else { return [] }

        let nsText = text as NSString
        var result: [Token] = []
        var isInsideFence = false

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines]
        ) { _, lineRange, _, _ in
            guard lineRange.length > 0 else { return }

            if fencePattern?.firstMatch(in: text, range: lineRange) != nil {
                result.append(Token(range: lineRange, kind: .codeFenceMarker))
                isInsideFence.toggle()
                return
            }

            if isInsideFence {
                result.append(Token(range: lineRange, kind: .codeBlockLine))
                return
            }

            if dividerPattern?.firstMatch(in: text, range: lineRange) != nil {
                result.append(Token(range: lineRange, kind: .divider))
                return
            }

            if let heading = headingPattern?.firstMatch(in: text, range: lineRange) {
                let hashRange = heading.range(at: 1)
                let spaceRange = heading.range(at: 2)
                let level = min(6, hashRange.length)
                result.append(Token(
                    range: NSRange(location: hashRange.location, length: NSMaxRange(spaceRange) - hashRange.location),
                    kind: .headingMarker
                ))
                let textRange = heading.range(at: 3)
                guard textRange.length > 0 else { return }
                result.append(Token(range: textRange, kind: .heading(level: level)))
                result.append(contentsOf: inlineTokens(in: text, range: textRange))
                return
            }

            var remainder = lineRange
            if let quote = blockquotePattern?.firstMatch(in: text, range: lineRange) {
                let markerEnd = NSMaxRange(quote.range)
                result.append(Token(
                    range: NSRange(location: lineRange.location, length: markerEnd - lineRange.location),
                    kind: .blockquoteMarker
                ))
                remainder = NSRange(location: markerEnd, length: NSMaxRange(lineRange) - markerEnd)
            } else if let list = listPattern?.firstMatch(in: text, range: lineRange) {
                let markerEnd = NSMaxRange(list.range)
                result.append(Token(
                    range: NSRange(location: lineRange.location, length: markerEnd - lineRange.location),
                    kind: .listMarker
                ))
                remainder = NSRange(location: markerEnd, length: NSMaxRange(lineRange) - markerEnd)
            }

            guard remainder.length > 0 else { return }
            result.append(contentsOf: inlineTokens(in: text, range: remainder))
        }

        return result
    }

    // MARK: - Inline scanning

    private enum InlineKind {
        case codeSpan
        case bold
        case italic
        case strikethrough
        case link
    }

    private static func inlineTokens(in text: String, range: NSRange) -> [Token] {
        var result: [Token] = []
        var searchRange = range

        while searchRange.length > 0 {
            var candidates: [(NSTextCheckingResult, InlineKind)] = []
            if let m = codeSpanPattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .codeSpan)) }
            if let m = boldAsteriskPattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .bold)) }
            if let m = boldUnderscorePattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .bold)) }
            if let m = strikethroughPattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .strikethrough)) }
            if let m = italicAsteriskPattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .italic)) }
            if let m = italicUnderscorePattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .italic)) }
            if let m = linkPattern?.firstMatch(in: text, range: searchRange) { candidates.append((m, .link)) }

            guard let (match, kind) = candidates.min(by: { $0.0.range.location < $1.0.range.location }) else {
                break
            }

            appendInlineTokens(for: match, kind: kind, into: &result)

            let newStart = NSMaxRange(match.range)
            searchRange = NSRange(location: newStart, length: NSMaxRange(range) - newStart)
        }

        return result
    }

    private static func appendInlineTokens(for match: NSTextCheckingResult, kind: InlineKind, into result: inout [Token]) {
        let full = match.range

        switch kind {
        case .codeSpan:
            let backtickLength = match.range(at: 1).length
            result.append(Token(range: NSRange(location: full.location, length: backtickLength), kind: .codeSpanMarker))
            result.append(Token(range: match.range(at: 2), kind: .codeSpan))
            result.append(Token(
                range: NSRange(location: NSMaxRange(full) - backtickLength, length: backtickLength),
                kind: .codeSpanMarker
            ))

        case .bold:
            result.append(Token(range: NSRange(location: full.location, length: 2), kind: .emphasisMarker))
            result.append(Token(range: match.range(at: 1), kind: .bold))
            result.append(Token(range: NSRange(location: NSMaxRange(full) - 2, length: 2), kind: .emphasisMarker))

        case .italic:
            result.append(Token(range: NSRange(location: full.location, length: 1), kind: .emphasisMarker))
            result.append(Token(range: match.range(at: 1), kind: .italic))
            result.append(Token(range: NSRange(location: NSMaxRange(full) - 1, length: 1), kind: .emphasisMarker))

        case .strikethrough:
            result.append(Token(range: NSRange(location: full.location, length: 2), kind: .emphasisMarker))
            result.append(Token(range: match.range(at: 1), kind: .strikethrough))
            result.append(Token(range: NSRange(location: NSMaxRange(full) - 2, length: 2), kind: .emphasisMarker))

        case .link:
            result.append(Token(range: match.range(at: 1), kind: .linkBracket))
            result.append(Token(range: match.range(at: 2), kind: .linkLabel))
            result.append(Token(range: match.range(at: 3), kind: .linkBracket))
            result.append(Token(range: match.range(at: 4), kind: .linkBracket))
            result.append(Token(range: match.range(at: 5), kind: .linkURL))
            result.append(Token(range: match.range(at: 6), kind: .linkBracket))
        }
    }

    // MARK: - Patterns

    private static let headingPattern = makePattern(#"^(#{1,6})(\s+)(.*)$"#)
    private static let dividerPattern = makePattern(#"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#)
    private static let blockquotePattern = makePattern(#"^\s*(?:>\s*)+"#)
    private static let listPattern = makePattern(#"^\s*([-*+]|\d+[.)])\s+"#)
    private static let fencePattern = makePattern(#"^\s*(```|~~~)"#)

    private static let codeSpanPattern = makePattern(#"(`+)([^`]+?)(?:\1)(?!`)"#)
    private static let boldAsteriskPattern = makePattern(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let boldUnderscorePattern = makePattern(#"__(?=\S)(.+?)(?<=\S)__"#)
    private static let italicAsteriskPattern = makePattern(#"(?<!\*)\*(?!\*)(?=\S)(.+?)(?<=\S)\*(?!\*)"#)
    private static let italicUnderscorePattern = makePattern(#"(?<!_)_(?!_)(?=\S)(.+?)(?<=\S)_(?!_)"#)
    private static let strikethroughPattern = makePattern(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let linkPattern = makePattern(#"(\[)([^\]\n]*)(\])(\()([^)\n]*)(\))"#)

    private static func makePattern(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
