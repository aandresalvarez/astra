import Foundation

struct SQLSyntaxToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case whitespace
        case word
        case number
        case stringLiteral
        case quotedIdentifier
        case lineComment
        case blockComment
        case symbol
    }

    var kind: Kind
    var text: String
    var range: NSRange
}

enum SQLSyntaxTokenizer {
    static let keywords: Set<String> = [
        "ALL", "ALTER", "AND", "ARRAY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CAST",
        "COUNT", "CREATE", "CROSS", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXCEPT",
        "FALSE", "FROM", "FULL", "GROUP", "HAVING", "IF", "IN", "INNER", "INSERT", "INTERSECT",
        "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "MERGE", "NOT", "NULL", "ON", "OR",
        "ORDER", "OUTER", "OVER", "QUALIFY", "REPLACE", "RIGHT", "SELECT", "SET", "THEN", "TRUE",
        "TRUNCATE", "UNION", "UPDATE", "WHEN", "WHERE", "WITH"
    ]

    static func tokens(in sql: String) -> [SQLSyntaxToken] {
        let nsString = sql as NSString
        var tokens: [SQLSyntaxToken] = []
        var index = 0

        while index < nsString.length {
            let start = index
            let character = nsString.character(at: index)

            if isWhitespace(character) {
                index += 1
                while index < nsString.length, isWhitespace(nsString.character(at: index)) {
                    index += 1
                }
                tokens.append(token(.whitespace, nsString: nsString, start: start, end: index))
            } else if character == hyphen,
                      index + 1 < nsString.length,
                      nsString.character(at: index + 1) == hyphen {
                index += 2
                while index < nsString.length, nsString.character(at: index) != newline {
                    index += 1
                }
                tokens.append(token(.lineComment, nsString: nsString, start: start, end: index))
            } else if character == slash,
                      index + 1 < nsString.length,
                      nsString.character(at: index + 1) == asterisk {
                index += 2
                while index + 1 < nsString.length {
                    if nsString.character(at: index) == asterisk,
                       nsString.character(at: index + 1) == slash {
                        index += 2
                        break
                    }
                    index += 1
                }
                tokens.append(token(.blockComment, nsString: nsString, start: start, end: index))
            } else if character == singleQuote || character == doubleQuote {
                index = scanQuotedString(in: nsString, from: index, quote: character)
                tokens.append(token(.stringLiteral, nsString: nsString, start: start, end: index))
            } else if character == backtick {
                index = scanQuotedString(in: nsString, from: index, quote: character)
                tokens.append(token(.quotedIdentifier, nsString: nsString, start: start, end: index))
            } else if isDigit(character) {
                index += 1
                while index < nsString.length, isNumberBody(nsString.character(at: index)) {
                    index += 1
                }
                tokens.append(token(.number, nsString: nsString, start: start, end: index))
            } else if isWordStart(character) {
                index += 1
                while index < nsString.length, isWordBody(nsString.character(at: index)) {
                    index += 1
                }
                tokens.append(token(.word, nsString: nsString, start: start, end: index))
            } else {
                index += 1
                tokens.append(token(.symbol, nsString: nsString, start: start, end: index))
            }
        }

        return tokens
    }

    static func isKeyword(_ text: String) -> Bool {
        keywords.contains(text.uppercased())
    }

    private static func token(_ kind: SQLSyntaxToken.Kind, nsString: NSString, start: Int, end: Int) -> SQLSyntaxToken {
        let range = NSRange(location: start, length: max(end - start, 0))
        return SQLSyntaxToken(kind: kind, text: nsString.substring(with: range), range: range)
    }

    private static func scanQuotedString(in nsString: NSString, from start: Int, quote: unichar) -> Int {
        var index = start + 1
        while index < nsString.length {
            let character = nsString.character(at: index)
            if character == quote {
                if index + 1 < nsString.length, nsString.character(at: index + 1) == quote {
                    index += 2
                    continue
                }
                index += 1
                break
            }
            index += 1
        }
        return index
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == space || character == tab || character == newline || character == carriageReturn
    }

    private static func isWordStart(_ character: unichar) -> Bool {
        (character >= uppercaseA && character <= uppercaseZ) ||
            (character >= lowercaseA && character <= lowercaseZ) ||
            character == underscore
    }

    private static func isWordBody(_ character: unichar) -> Bool {
        isWordStart(character) || isDigit(character) || character == dollar
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= zero && character <= nine
    }

    private static func isNumberBody(_ character: unichar) -> Bool {
        isDigit(character) || character == dot
    }

    private static let tab: unichar = 9
    private static let newline: unichar = 10
    private static let carriageReturn: unichar = 13
    private static let space: unichar = 32
    private static let doubleQuote: unichar = 34
    private static let dollar: unichar = 36
    private static let singleQuote: unichar = 39
    private static let asterisk: unichar = 42
    private static let dot: unichar = 46
    private static let slash: unichar = 47
    private static let zero: unichar = 48
    private static let nine: unichar = 57
    private static let uppercaseA: unichar = 65
    private static let uppercaseZ: unichar = 90
    private static let backtick: unichar = 96
    private static let lowercaseA: unichar = 97
    private static let lowercaseZ: unichar = 122
    private static let underscore: unichar = 95
    private static let hyphen: unichar = 45
}

enum SQLFormatter {
    static func format(_ sql: String) -> String {
        let tokens = SQLSyntaxTokenizer.tokens(in: sql).filter { $0.kind != .whitespace }
        guard !tokens.isEmpty else { return "" }

        var output = ""
        var clause: Clause = .none
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            switch token.kind {
            case .lineComment, .blockComment:
                appendComment(token.text.trimmingCharacters(in: .whitespacesAndNewlines), to: &output)
            case .word:
                let upper = token.text.uppercased()
                if upper == "UNION" {
                    appendBlankLine(to: &output)
                    appendWord(unionPhrase(tokens: tokens, index: index), to: &output)
                    appendBlankLine(to: &output)
                    if nextWord(tokens: tokens, index: index) == "ALL" || nextWord(tokens: tokens, index: index) == "DISTINCT" {
                        index += 1
                    }
                    clause = .none
                } else if upper == "GROUP", nextWord(tokens: tokens, index: index) == "BY" {
                    startClause("GROUP BY", clause: .group, output: &output)
                    index += 1
                    clause = .group
                } else if upper == "ORDER", nextWord(tokens: tokens, index: index) == "BY" {
                    startClause("ORDER BY", clause: .order, output: &output)
                    index += 1
                    clause = .order
                } else if let joinPhrase = joinPhrase(tokens: tokens, index: index) {
                    startClause(joinPhrase.text, clause: .join, output: &output)
                    index += joinPhrase.extraTokens
                    clause = .join
                } else if let nextClause = Clause.keywordClause(upper) {
                    startClause(keywordText(upper, original: token.text), clause: nextClause, output: &output)
                    clause = nextClause
                } else if (upper == "AND" || upper == "OR"), clause.breaksBooleanPredicates {
                    appendNewLine(to: &output, indent: 4)
                    appendWord(upper, to: &output)
                } else {
                    appendWord(keywordText(upper, original: token.text), to: &output)
                }
            case .symbol:
                appendSymbol(token.text, currentClause: clause, to: &output)
            default:
                appendWord(token.text, to: &output)
            }

            index += 1
        }

        return output
            .components(separatedBy: .newlines)
            .map { trimTrailingWhitespace($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Clause {
        case none
        case with
        case select
        case from
        case whereClause
        case group
        case order
        case having
        case limit
        case join
        case other

        static func keywordClause(_ keyword: String) -> Clause? {
            switch keyword {
            case "WITH": .with
            case "SELECT": .select
            case "FROM": .from
            case "WHERE": .whereClause
            case "ON": .join
            case "HAVING": .having
            case "LIMIT": .limit
            case "QUALIFY": .whereClause
            default: nil
            }
        }

        var breaksBooleanPredicates: Bool {
            switch self {
            case .whereClause, .having, .join:
                return true
            case .none, .with, .select, .from, .group, .order, .limit, .other:
                return false
            }
        }
    }

    private static func startClause(_ text: String, clause newClause: Clause, output: inout String) {
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendNewLine(to: &output)
        }
        appendWord(text, to: &output)
        output += " "
        _ = newClause
    }

    private static func keywordText(_ upper: String, original: String) -> String {
        SQLSyntaxTokenizer.isKeyword(upper) ? upper : original
    }

    private static func unionPhrase(tokens: [SQLSyntaxToken], index: Int) -> String {
        guard let next = nextWord(tokens: tokens, index: index),
              next == "ALL" || next == "DISTINCT" else {
            return "UNION"
        }
        return "UNION \(next)"
    }

    private static func joinPhrase(tokens: [SQLSyntaxToken], index: Int) -> (text: String, extraTokens: Int)? {
        guard index < tokens.count, tokens[index].kind == .word else { return nil }
        let upper = tokens[index].text.uppercased()

        if upper == "JOIN" {
            return ("JOIN", 0)
        }

        guard ["LEFT", "RIGHT", "FULL", "INNER", "CROSS"].contains(upper) else {
            return nil
        }

        if nextWord(tokens: tokens, index: index) == "OUTER",
           word(tokens: tokens, at: index + 2) == "JOIN" {
            return ("\(upper) OUTER JOIN", 2)
        }

        if nextWord(tokens: tokens, index: index) == "JOIN" {
            return ("\(upper) JOIN", 1)
        }

        return nil
    }

    private static func nextWord(tokens: [SQLSyntaxToken], index: Int) -> String? {
        guard index + 1 < tokens.count, tokens[index + 1].kind == .word else { return nil }
        return tokens[index + 1].text.uppercased()
    }

    private static func word(tokens: [SQLSyntaxToken], at index: Int) -> String? {
        guard index < tokens.count, tokens[index].kind == .word else { return nil }
        return tokens[index].text.uppercased()
    }

    private static func appendComment(_ comment: String, to output: inout String) {
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendNewLine(to: &output)
        }
        output += comment
        appendNewLine(to: &output)
    }

    private static func appendWord(_ word: String, to output: inout String) {
        if needsSpaceBeforeWord(output) {
            output += " "
        }
        output += word
    }

    private static func appendSymbol(_ symbol: String, currentClause: Clause, to output: inout String) {
        switch symbol {
        case ",":
            trimTrailingSpace(&output)
            output += ","
            if currentClause == .select {
                appendNewLine(to: &output, indent: 4)
            } else {
                output += " "
            }
        case ".":
            trimTrailingSpace(&output)
            output += "."
        case "(":
            trimTrailingSpace(&output)
            output += "("
        case ")":
            trimTrailingSpace(&output)
            output += ")"
        case ";":
            trimTrailingSpace(&output)
            output += ";"
        default:
            appendWord(symbol, to: &output)
        }
    }

    private static func appendNewLine(to output: inout String, indent: Int = 0) {
        trimTrailingSpace(&output)
        guard !output.hasSuffix("\n") else {
            output += String(repeating: " ", count: indent)
            return
        }
        output += "\n" + String(repeating: " ", count: indent)
    }

    private static func appendBlankLine(to output: inout String) {
        trimTrailingSpace(&output)
        if output.isEmpty { return }
        if output.hasSuffix("\n\n") { return }
        if output.hasSuffix("\n") {
            output += "\n"
        } else {
            output += "\n\n"
        }
    }

    private static func needsSpaceBeforeWord(_ output: String) -> Bool {
        guard let last = output.last else { return false }
        return !last.isWhitespace && last != "(" && last != "." && last != "\n"
    }

    private static func trimTrailingSpace(_ output: inout String) {
        while output.last == " " || output.last == "\t" {
            output.removeLast()
        }
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var line = line
        while line.last == " " || line.last == "\t" {
            line.removeLast()
        }
        return line
    }
}
