import Foundation

enum PrivacySensitivePathPolicy {
    private static let protectedHomeRelativeDirectories: [[String]] = [
        ["Pictures"],
        ["Music"],
        ["Movies"],
        ["Library", "Photos"],
        ["Library", "Mail"],
        ["Library", "Messages"],
        ["Library", "Calendars"],
        ["Library", "Application Support", "AddressBook"]
    ]

    private static let protectedAbsoluteDirectories: [String] = [
        "/Applications",
        "/System/Applications",
        "/Volumes",
        "/Network"
    ]

    private static let protectedPackageExtensions: Set<String> = [
        "app",
        "photoslibrary",
        "musiclibrary",
        "medialibrary"
    ]

    static func shouldSkipImplicitScan(
        of url: URL,
        scanRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = normalizedPath(url)
        if let scanRoot, path == normalizedPath(scanRoot) {
            return false
        }

        if protectedPackageExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        return protectedDirectoryPaths(homeDirectory: homeDirectory).contains { protectedPath in
            path == protectedPath || path.hasPrefix(protectedPath + "/")
        }
    }

    static func protectedDirectoryPaths(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let home = normalizedPath(homeDirectory)
        let homePaths = protectedHomeRelativeDirectories.map { components in
            components.reduce(URL(fileURLWithPath: home, isDirectory: true)) { url, component in
                url.appendingPathComponent(component, isDirectory: true)
            }.standardizedFileURL.path
        }
        return homePaths + protectedAbsoluteDirectories
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
