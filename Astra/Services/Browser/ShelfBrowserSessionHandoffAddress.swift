import Foundation

extension ShelfBrowserSession {
    static func isDisplayablePageURL(_ value: String) -> Bool {
        let normalizedURL = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedURL.isEmpty && normalizedURL != "about:blank"
    }

    static func controlledBrowserHandoffAddress(currentURL: String, webViewURL: URL?) -> String? {
        firstDisplayableHandoffAddress([
            webViewURL?.absoluteString,
            currentURL
        ])
    }

    static func embeddedBrowserHandoffAddress(currentURL: String, controlledURL: String) -> String? {
        firstDisplayableHandoffAddress([controlledURL, currentURL])
    }

    private static func firstDisplayableHandoffAddress(_ candidates: [String?]) -> String? {
        for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard isDisplayablePageURL(candidate),
                  let normalized = ShelfBrowserAddress.normalizedURL(from: candidate) else {
                continue
            }
            return normalized.absoluteString
        }
        return nil
    }
}
