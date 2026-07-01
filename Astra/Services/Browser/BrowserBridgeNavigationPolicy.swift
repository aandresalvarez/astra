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

    static func openControlNavigation(forHref href: String, pageURL: String? = nil) -> OpenControlNavigation {
        let trimmedHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHref.isEmpty else {
            return .fallbackToActivation
        }
        let candidate = resolvedHref(trimmedHref, pageURL: pageURL)
        guard let url = normalizedProviderURL(from: candidate) else {
            return .reject
        }
        return .navigate(url)
    }

    private static func resolvedHref(_ href: String, pageURL: String?) -> String {
        guard let pageURL,
              let baseURL = URL(string: pageURL),
              let resolvedURL = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
            return href
        }
        return resolvedURL.absoluteString
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
