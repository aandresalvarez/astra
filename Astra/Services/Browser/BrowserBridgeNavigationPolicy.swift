import Foundation

enum BrowserBridgeNavigationPolicy {
    enum OpenControlNavigation: Equatable {
        case fallbackToActivation
        case navigate(URL)
        case reject
    }

    private static let allowedSchemes: Set<String> = ["http", "https"]

    static func normalizedProviderURL(from input: String) -> URL? {
        guard let url = ShelfBrowserAddress.normalizedURL(from: input) else {
            return nil
        }
        return isAllowedProviderURL(url) ? url : nil
    }

    static func openControlNavigation(forHref href: String) -> OpenControlNavigation {
        let trimmedHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHref.isEmpty else {
            return .fallbackToActivation
        }
        guard let url = normalizedProviderURL(from: trimmedHref) else {
            return .reject
        }
        return .navigate(url)
    }

    private static func isAllowedProviderURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        guard allowedSchemes.contains(scheme),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return false
        }
        return true
    }
}
