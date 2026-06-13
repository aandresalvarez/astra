import Foundation

enum HostFileAccessIntent: Equatable {
    case explicitUserSelection
    case astraManagedStorage(root: URL)
    case implicitScan(root: URL?)
}

enum HostFileAccessError: Error, Equatable {
    case accessDenied(path: String)
}

struct HostFileAccessBroker {
    let fileManager: FileManager
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func shouldSkip(_ url: URL, intent: HostFileAccessIntent) -> Bool {
        switch intent {
        case .explicitUserSelection:
            return false
        case .astraManagedStorage(let root):
            return !Self.isPath(url, inside: root)
        case .implicitScan(let root):
            return PrivacySensitivePathPolicy.shouldSkipImplicitScan(
                of: url,
                scanRoot: root,
                homeDirectory: homeDirectory
            )
        }
    }

    func fileExists(
        at url: URL,
        isDirectory: UnsafeMutablePointer<ObjCBool>? = nil,
        intent: HostFileAccessIntent
    ) -> Bool {
        guard !shouldSkip(url, intent: intent) else {
            isDirectory?.pointee = false
            return false
        }
        return fileManager.fileExists(atPath: url.path, isDirectory: isDirectory)
    }

    func readData(at url: URL, intent: HostFileAccessIntent) throws -> Data {
        try requireAccess(to: url, intent: intent)
        return try Data(contentsOf: url)
    }

    func readString(
        at url: URL,
        encoding: String.Encoding = .utf8,
        intent: HostFileAccessIntent
    ) throws -> String {
        try requireAccess(to: url, intent: intent)
        return try String(contentsOf: url, encoding: encoding)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        intent: HostFileAccessIntent
    ) throws -> [URL] {
        guard !shouldSkip(url, intent: intent) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
        .filter { !shouldSkip($0, intent: intent) }
    }

    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        intent: HostFileAccessIntent
    ) -> FileManager.DirectoryEnumerator? {
        guard !shouldSkip(url, intent: intent) else {
            return nil
        }
        return fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }

    private func requireAccess(to url: URL, intent: HostFileAccessIntent) throws {
        guard !shouldSkip(url, intent: intent) else {
            throw HostFileAccessError.accessDenied(path: url.path)
        }
    }

    private static func isPath(_ url: URL, inside root: URL) -> Bool {
        let path = normalizedPath(url)
        let rootPath = normalizedPath(root)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
