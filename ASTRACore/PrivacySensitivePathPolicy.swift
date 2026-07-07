import Foundation

public enum PrivacySensitivePathPolicy {
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

    public static func shouldSkipImplicitScan(
        of url: URL,
        scanRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = normalizedPath(url)
        let protectedPaths = protectedDirectoryPaths(homeDirectory: homeDirectory)

        if protectedPackageExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        if let scanRoot {
            let rootPath = normalizedPath(scanRoot)
            if protectedPaths.contains(where: { isPath(rootPath, insideOrEqualTo: $0) }),
               isPath(path, insideOrEqualTo: rootPath) {
                return false
            }
        }

        return protectedPaths.contains { protectedPath in
            path == protectedPath || path.hasPrefix(protectedPath + "/")
        }
    }

    public static func protectedDirectoryPaths(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
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

    private static func isPath(_ path: String, insideOrEqualTo rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
