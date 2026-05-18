import Foundation

enum MailTaskIntent {
    static func isReadOnlyMailRequest(_ values: [String]) -> Bool {
        let text = normalize(values.joined(separator: " "))
        guard containsAny(text, readTerms) else { return false }
        return !containsAny(text, mutationTerms)
    }

    static func isOutlookURL(_ value: String?) -> Bool {
        guard let value,
              let host = URL(string: value)?.host?.lowercased() else { return false }
        return host.contains("outlook.")
            || host == "outlook.office.com"
            || host == "outlook.cloud.microsoft"
            || host.hasSuffix(".outlook.office.com")
            || host.hasSuffix(".outlook.cloud.microsoft")
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        let padded = " \(text) "
        return terms.contains { padded.contains(" \($0) ") }
    }

    private static let readTerms = [
        "email",
        "emails",
        "mail",
        "message",
        "messages",
        "inbox",
        "outlook"
    ]

    private static let mutationTerms = [
        "compose",
        "draft",
        "write",
        "send",
        "sent",
        "reply",
        "forward",
        "delete",
        "archive",
        "move",
        "mark",
        "junk",
        "phishing"
    ]
}
