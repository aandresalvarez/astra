import Foundation

enum AstraResourceBundle {
    private static let resourceBundleName = "ASTRA_ASTRA"

    static var current: Bundle {
        let candidateURLs = [
            Bundle.main.url(forResource: resourceBundleName, withExtension: "bundle"),
            Bundle.main.resourceURL?.appendingPathComponent("\(resourceBundleName).bundle", isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent("\(resourceBundleName).bundle", isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(resourceBundleName).bundle", isDirectory: true),
            Bundle(for: BundleAnchor.self).url(forResource: resourceBundleName, withExtension: "bundle"),
            Bundle(for: BundleAnchor.self).resourceURL?.appendingPathComponent("\(resourceBundleName).bundle", isDirectory: true),
            Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("\(resourceBundleName).bundle", isDirectory: true)
        ]

        for url in candidateURLs.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        return Bundle.main
    }
}

private final class BundleAnchor {}
