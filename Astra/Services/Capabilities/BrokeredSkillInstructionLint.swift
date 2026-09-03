import Foundation
import ASTRACore

/// Catches a skill that tells the agent to use a credential ASTRA will not give it.
///
/// The incident: a user-authored attestation skill instructed the agent to call
/// Jira with `JIRA_EMAIL`/`JIRA_API_TOKEN` over Basic auth. Those variables are
/// no longer projected — a broker holds them — so the agent did the only thing
/// the instructions allowed and reported a missing credential. The failure was
/// silent at authoring time and confusing at run time, which is backwards: the
/// text is wrong when it is written, so that is where it should be flagged.
///
/// The brokered set is read from `HostControlPlaneMCPProjection`, never restated
/// here, so a service that gains a broker starts linting on the same commit.
enum BrokeredSkillInstructionLint {
    enum Source: String, Equatable, Sendable {
        case instructions
        case environmentKey

        var label: String {
            switch self {
            case .instructions: "Instructions"
            case .environmentKey: "Parameter"
            }
        }
    }

    struct Finding: Equatable, Identifiable, Sendable {
        let environmentKey: String
        let serviceType: String
        let toolName: String
        let source: Source

        var id: String { "\(source.rawValue):\(environmentKey)" }

        var route: String { "mcp__astra_host__\(toolName)" }

        var message: String {
            "\(source.label) reference `\(environmentKey)` will not resolve: ASTRA keeps "
                + "\(serviceType) credentials in its broker and does not put them in the agent's "
                + "environment. Use `\(route)` instead."
        }
    }

    /// Matches shell-style environment variable names, with or without a `$`.
    /// Deliberately requires an underscore: bare words like `JIRA` are prose,
    /// while `JIRA_API_TOKEN` is an instruction to read a variable.
    private static let environmentTokenPattern = try? NSRegularExpression(
        pattern: "[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+"
    )

    static func findings(instructions: String, environmentKeys: [String] = []) -> [Finding] {
        var seen: Set<String> = []
        var findings: [Finding] = []
        for token in environmentTokens(in: instructions) {
            guard !isNegated(token, in: instructions),
                  let finding = finding(for: token.text, source: .instructions),
                  seen.insert(finding.id).inserted else { continue }
            findings.append(finding)
        }
        for key in environmentKeys {
            guard let finding = finding(for: key, source: .environmentKey),
                  seen.insert(finding.id).inserted else { continue }
            findings.append(finding)
        }
        return findings
    }

    private static func finding(for token: String, source: Source) -> Finding? {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard isCredentialShaped(key) else { return nil }
        // The service is the leading segment: `REDCAP_API_TOKEN`, and equally
        // the namespaced `REDCAP_STUDY_A_API_TOKEN`, both belong to `redcap`.
        guard let prefix = key.split(separator: "_").first.map(String.init) else { return nil }
        let serviceType = prefix.lowercased()
        guard HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration(serviceType),
              let toolName = HostControlPlaneMCPProjection.connectorToolName(serviceType) else {
            return nil
        }
        return Finding(
            environmentKey: key,
            serviceType: serviceType,
            toolName: toolName,
            source: source
        )
    }

    /// Only authentication material is worth flagging. A brokered connector's
    /// base URL and project list are stripped too, but a skill that names
    /// `JIRA_BASE_URL` is describing a site, not reaching for a secret - and
    /// ASTRA's own shipped Jira skill declares exactly that parameter. A lint
    /// that fires on the app's own capabilities is one authors learn to ignore.
    private static func isCredentialShaped(_ key: String) -> Bool {
        if RunSecretRedaction.isSecretKey(key) { return true }
        // The identity half of a credential pair: useless alone, and only ever
        // present to authenticate. `JIRA_EMAIL` is what the incident's skill
        // paired with the token for Basic auth.
        guard let last = key.split(separator: "_").last.map(String.init) else { return false }
        return ["EMAIL", "USER", "USERNAME", "LOGIN", "ACCOUNT"].contains(last)
    }

    /// Whether the sentence around a mention forbids it rather than instructs
    /// it. ASTRA's brokered skills name the variable in order to rule it out
    /// ("do not look for REDCAP_API_TOKEN ... those values are deliberately
    /// absent"), which is the behaviour this lint exists to produce.
    private static func isNegated(_ token: EnvironmentToken, in text: String) -> Bool {
        guard let negationPattern else { return false }
        let sentence = enclosingSentence(of: token.range, in: text)
        let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
        return negationPattern.firstMatch(in: sentence, range: range) != nil
    }

    private static func enclosingSentence(of range: Range<String.Index>, in text: String) -> String {
        let boundaries: Set<Character> = [".", "!", "?", "\n", ";", "•"]
        var start = range.lowerBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            if boundaries.contains(text[previous]) { break }
            start = previous
        }
        var end = range.upperBound
        while end < text.endIndex, !boundaries.contains(text[end]) {
            end = text.index(after: end)
        }
        return String(text[start..<end])
    }

    private struct EnvironmentToken {
        let text: String
        let range: Range<String.Index>
    }

    private static let negationPattern = try? NSRegularExpression(
        pattern: "\\b(?:do not|don['’]t|never|cannot|can['’]t|will not|won['’]t|is not|are not|"
            + "no longer|instead of|deliberately absent|not in your|stale)\\b",
        options: [.caseInsensitive]
    )

    private static func environmentTokens(in text: String) -> [EnvironmentToken] {
        guard let environmentTokenPattern, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return environmentTokenPattern.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return EnvironmentToken(text: String(text[matchRange]), range: matchRange)
        }
    }
}
