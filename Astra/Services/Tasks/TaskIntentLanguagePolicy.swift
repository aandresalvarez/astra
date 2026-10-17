import Foundation

/// Deterministic intent parsing shared by scheduling and deliverable policy.
///
/// ASTRA is intentionally conservative: this recognizes only explicit
/// clause-local prohibitions. Wording outside this small grammar remains
/// subject to each caller's fail-closed behavior.
enum TaskIntentLanguagePolicy {
    private static let negationWords: Set<String> = ["avoid", "never", "not", "without"]

    static func containsAffirmativeAction(
        in text: String,
        words: Set<String>,
        phrases: [String] = []
    ) -> Bool {
        let phraseTokens = phrases.map(tokens)
        for clause in clauses(in: text) {
            let clauseTokens = tokens(clause)
            var actionIsNegated = false
            for (index, token) in clauseTokens.enumerated() {
                if negationWords.contains(token) {
                    actionIsNegated = true
                    continue
                }
                guard !actionIsNegated else { continue }
                if words.contains(token) { return true }
                if phraseTokens.contains(where: { phrase in
                    !phrase.isEmpty
                        && index + phrase.count <= clauseTokens.count
                        && Array(clauseTokens[index..<(index + phrase.count)]) == phrase
                }) {
                    return true
                }
            }
        }
        return false
    }

    /// Keep an action with its object, rather than borrowing a noun from a
    /// different instruction. Nested verbs stay in that object's description;
    /// an explicit coordinated instruction starts a new action.
    static func affirmativeActionObjects(in text: String, words: Set<String>) -> [(verb: String, object: String)] {
        let forms = words.flatMap { [$0, "\($0)a", "\($0)an"] }
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let actionPattern = "\\b(?:\(forms))\\b"
        let coordination = "\\band\\s+(?=(?:(?:also|please|do|not|never)\\s+)*\(actionPattern))"
        var result: [(verb: String, object: String)] = []
        // A creation header governs its first list item, not an unrelated
        // later clause: "Create:\n- a website" is one requested object.
        let instructions = text.replacingOccurrences(
            of: "(\(actionPattern))(?:\\s+the\\s+following)?\\s*:\\s*(?:[-*]\\s*)?",
            with: "$1 ", options: [.regularExpression, .caseInsensitive]
        )
        // A filename's dot belongs to the requested object, rather than ending
        // the instruction before its extension ("create preview.html"). Keep
        // the existing action-only parser's clause behavior unchanged.
        let filenameDots = instructions.replacingOccurrences(
            of: #"(?<=[\p{L}\p{N}_/\-])\.(?=[\p{L}\p{N}])"#,
            with: "\u{001E}", options: .regularExpression
        )
        for protectedClause in clauses(in: filenameDots) {
            let clause = protectedClause.replacingOccurrences(of: "\u{001E}", with: ".")
            let parts = clause.replacingOccurrences(of: coordination, with: "\u{001F}", options: .regularExpression)
                .components(separatedBy: "\u{001F}")
            var precedingText = ""
            for part in parts {
                guard let action = part.range(of: actionPattern, options: .regularExpression) else {
                    precedingText += part + " "
                    continue
                }
                let prefix = precedingText + part[..<action.lowerBound]
                // Carry a prohibition on the action across "and", without
                // treating "not too long" inside its object as a prohibition
                // on the next independent request.
                precedingText = prefix + " "
                guard !tokens(prefix).contains(where: negationWords.contains) else { continue }
                let matched = String(part[action])
                guard let verb = words.first(where: { matched == $0 || matched == $0 + "a" || matched == $0 + "an" }) else { continue }
                result.append((verb, String(part[action.upperBound...])))
            }
        }
        return result
    }

    private static func clauses(in text: String) -> [String] {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "don’t", with: "do not")
            .replacingOccurrences(of: "don't", with: "do not")
            .replacingOccurrences(of: "mustn’t", with: "must not")
            .replacingOccurrences(of: "mustn't", with: "must not")
            .replacingOccurrences(of: " but ", with: ".")
            .replacingOccurrences(of: " however ", with: ".")
            .replacingOccurrences(of: " then ", with: ".")
            .replacingOccurrences(of: " - ", with: ".")
        // Dashes commonly introduce the affirmative correction to a negated
        // action ("don't review—fix"). They are semantic clause boundaries,
        // not punctuation that should let negation leak into the correction.
        return normalized.components(separatedBy: CharacterSet(charactersIn: ".,;:!?—–\n"))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
