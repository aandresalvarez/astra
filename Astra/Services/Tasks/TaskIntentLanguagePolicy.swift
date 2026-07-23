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
