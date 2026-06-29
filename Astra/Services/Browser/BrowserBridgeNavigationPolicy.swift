import Foundation

enum BrowserBridgeNavigationPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https"]

    static func normalizedProviderURL(from input: String) -> URL? {
        guard let url = ShelfBrowserAddress.normalizedURL(from: input) else {
            return nil
        }
        return isAllowedProviderURL(url) ? url : nil
    }

    static func isAllowedProviderURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return allowedSchemes.contains(scheme)
    }
}
