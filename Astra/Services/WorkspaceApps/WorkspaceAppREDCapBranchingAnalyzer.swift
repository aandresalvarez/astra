import Foundation

/// Slice 5: classifies a REDCap field's branching-logic expression as either safely
/// representable by ASTRA or unsupported. REDCap remains the system of record; ASTRA only
/// reproduces branching it can honor EXACTLY. Anything outside the conservative subset is
/// `unsupported`, so the form builder can warn and block submit / route to review rather
/// than silently approximate show/hide logic (spec §3.2, §17.x).
///
/// Safe subset (deliberately small): one or more `[field] <op> value` comparisons joined
/// by a SINGLE combinator (all `and`, or all `or` — never mixed). Operators: = <> != > < >= <=.
/// Values: a quoted string or a number. Everything else — functions (`datediff(...)`),
/// arithmetic, grouping parentheses, negation, smart variables / event or checkbox codes
/// (`[a][b]`), and mixed and/or — is unsupported.
enum WorkspaceAppREDCapBranchingSafety: Equatable {
    case safe(WorkspaceAppREDCapBranchingCondition)
    case unsupported(reason: String)
}

/// A normalized, safe branching condition. Empty `clauses` means "always shown".
struct WorkspaceAppREDCapBranchingCondition: Equatable {
    enum Combinator: String, Equatable { case and, or }
    enum Comparison: String, Equatable { case equals, notEquals, greaterThan, lessThan, greaterOrEqual, lessOrEqual }
    struct Clause: Equatable {
        var field: String
        var comparison: Comparison
        var value: String
    }
    var combinator: Combinator
    var clauses: [Clause]

    var isAlwaysVisible: Bool { clauses.isEmpty }
}

enum WorkspaceAppREDCapBranchingAnalyzer {
    static func classify(_ rawLogic: String) -> WorkspaceAppREDCapBranchingSafety {
        let logic = rawLogic.trimmingCharacters(in: .whitespacesAndNewlines)
        if logic.isEmpty {
            return .safe(WorkspaceAppREDCapBranchingCondition(combinator: .and, clauses: []))
        }

        // Reject constructs we will not approximate, each with a precise reason.
        if contains(#"\]\s*\["#, logic) {
            return .unsupported(reason: "Smart variables, event prefixes, or checkbox codes (e.g. [a][b]) are not supported.")
        }
        if contains(#"[A-Za-z_][A-Za-z0-9_]*\s*\("#, logic) {
            return .unsupported(reason: "Function calls (e.g. datediff, if, sum) are not supported.")
        }
        if logic.contains("(") || logic.contains(")") {
            return .unsupported(reason: "Grouping parentheses are not supported.")
        }
        if contains(#"[+*/]"#, logic) {
            return .unsupported(reason: "Arithmetic expressions are not supported.")
        }

        let hasAnd = contains(#"\s+and\s+"#, logic)
        let hasOr = contains(#"\s+or\s+"#, logic)
        if hasAnd && hasOr {
            return .unsupported(reason: "Mixed 'and'/'or' without grouping is ambiguous and not supported.")
        }

        let combinator: WorkspaceAppREDCapBranchingCondition.Combinator = hasOr ? .or : .and
        let rawClauses = hasOr ? split(logic, on: #"\s+or\s+"#)
            : hasAnd ? split(logic, on: #"\s+and\s+"#)
            : [logic]

        var clauses: [WorkspaceAppREDCapBranchingCondition.Clause] = []
        for raw in rawClauses {
            guard let clause = parseClause(raw) else {
                return .unsupported(reason: "Condition '\(raw.trimmingCharacters(in: .whitespaces))' is not a simple [field] <op> value comparison.")
            }
            clauses.append(clause)
        }
        return .safe(WorkspaceAppREDCapBranchingCondition(combinator: combinator, clauses: clauses))
    }

    // MARK: - Clause parsing

    private static func parseClause(_ raw: String) -> WorkspaceAppREDCapBranchingCondition.Clause? {
        // Multi-char operators must be tried before their single-char prefixes.
        let pattern = #"^\s*\[([A-Za-z0-9_]+)\]\s*(<=|>=|<>|!=|=|<|>)\s*('[^']*'|"[^"]*"|-?\d+(?:\.\d+)?)\s*$"#
        guard let groups = firstMatch(pattern, in: raw), groups.count == 4 else { return nil }
        guard let comparison = comparison(for: groups[2]) else { return nil }
        return WorkspaceAppREDCapBranchingCondition.Clause(
            field: groups[1],
            comparison: comparison,
            value: unquote(groups[3])
        )
    }

    private static func comparison(for token: String) -> WorkspaceAppREDCapBranchingCondition.Comparison? {
        switch token {
        case "=": return .equals
        case "<>", "!=": return .notEquals
        case ">": return .greaterThan
        case "<": return .lessThan
        case ">=": return .greaterOrEqual
        case "<=": return .lessOrEqual
        default: return nil
        }
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2 {
            let first = value.first, last = value.last
            if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
                return String(value.dropFirst().dropLast())
            }
        }
        return value
    }

    // MARK: - Regex helpers

    private static func contains(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let r = Range(match.range(at: index), in: text) else { return "" }
            return String(text[r])
        }
    }

    private static func split(_ text: String, on pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }
        let ns = text as NSString
        var pieces: [String] = []
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match else { return }
            pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: cursor))
        return pieces
    }
}
