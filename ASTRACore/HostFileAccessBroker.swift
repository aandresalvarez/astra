import Foundation
import Darwin

public enum HostFileAccessIntent: Equatable {
    case explicitUserSelection
    case astraManagedStorage(root: URL)
    case implicitScan(root: URL?)
}

public enum HostFileAccessError: Error, Equatable {
    case accessDenied(path: String)
}

public enum HostFileReadBound: Equatable {
    case prefix
    case suffix
}

public struct HostFileAccessBroker {
    public let fileManager: FileManager
    public let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    public func shouldSkip(_ url: URL, intent: HostFileAccessIntent) -> Bool {
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

    public func fileExists(
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

    /// The type of the item at `url`, following links, or nil only when it
    /// is confirmed missing or the policy skips it. A stat that fails for
    /// another reason throws: the item may be there.
    public func itemType(at url: URL, intent: HostFileAccessIntent) throws -> FileAttributeType? {
        guard !shouldSkip(url, intent: intent) else { return nil }
        // Recovery only needs the type. Foundation also reads extended
        // attributes, which can block on cloud/network metadata for minutes.
        // Preserve an injected filesystem's behavior rather than bypassing it.
        if fileManager === FileManager.default {
            var metadata = stat()
            let code = url.path.withCString { path in
                fstatat(AT_FDCWD, path, &metadata, 0) == 0 ? 0 : errno
            }
            guard code == 0 else {
                if code == ENOENT || code == ENOTDIR { return nil }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                              userInfo: [NSFilePathErrorKey: url.path])
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR: return .typeDirectory
            case S_IFREG: return .typeRegular
            case S_IFSOCK: return .typeSocket
            case S_IFCHR: return .typeCharacterSpecial
            case S_IFBLK: return .typeBlockSpecial
            default: return .typeUnknown
            }
        }
        do {
            return try fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.type] as? FileAttributeType
        } catch {
            let nsError = error as NSError
            let missing = (nsError.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code))
                || (nsError.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(nsError.code))
            if missing { return nil }
            throw error
        }
    }

    public func readData(at url: URL, intent: HostFileAccessIntent) throws -> Data {
        try requireAccess(to: url, intent: intent)
        if let data = fileManager.contents(atPath: url.path) { return data }
        // contents(atPath:) loses its error. Query the same injected filesystem
        // to distinguish a missing entry from a denied read without bypassing it.
        _ = try fileManager.attributesOfItem(atPath: url.path)
        let code: CocoaError.Code = fileManager.isReadableFile(atPath: url.path) ? .fileReadUnknown : .fileReadNoPermission
        throw CocoaError(code, userInfo: [NSFilePathErrorKey: url.path])
    }

    public func readData(
        at url: URL,
        maxBytes: Int,
        keeping bound: HostFileReadBound,
        intent: HostFileAccessIntent
    ) throws -> Data {
        try requireAccess(to: url, intent: intent)
        guard maxBytes > 0 else { return Data() }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        switch bound {
        case .prefix:
            return try handle.read(upToCount: maxBytes) ?? Data()
        case .suffix:
            let endOffset = try handle.seekToEnd()
            let bytesToRead = min(UInt64(maxBytes), endOffset)
            try handle.seek(toOffset: endOffset - bytesToRead)
            return try handle.read(upToCount: Int(bytesToRead)) ?? Data()
        }
    }

    public func fileSize(at url: URL, intent: HostFileAccessIntent) -> Int? {
        guard !shouldSkip(url, intent: intent) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              values.isDirectory != true else {
            return nil
        }
        return values.fileSize
    }

    public func readString(
        at url: URL,
        encoding: String.Encoding = .utf8,
        intent: HostFileAccessIntent
    ) throws -> String {
        let data = try readData(at: url, intent: intent)
        guard let string = String(data: data, encoding: encoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    public func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        intent: HostFileAccessIntent
    ) throws -> [URL] {
        guard !shouldSkip(url, intent: intent) else {
            return []
        }
        let requestedKeys = safeResourceKeys(keys, intent: intent)
        return try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: requestedKeys,
            options: mask
        )
        .filter { !shouldSkip($0, intent: intent) }
    }

    /// `contentsOfDirectory`, with the children the policy left out, so a
    /// scan that must see everything can tell when it didn't.
    public func contentsOfDirectoryReportingSkipped(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        intent: HostFileAccessIntent
    ) throws -> (contents: [URL], skipped: [URL]) {
        guard !shouldSkip(url, intent: intent) else { return ([], [url]) }
        let all = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: safeResourceKeys(keys, intent: intent),
            options: mask
        )
        return (all.filter { !shouldSkip($0, intent: intent) }, all.filter { shouldSkip($0, intent: intent) })
    }

    public func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        intent: HostFileAccessIntent,
        errorHandler: ((URL, any Error) -> Bool)? = nil
    ) -> FileManager.DirectoryEnumerator? {
        guard !shouldSkip(url, intent: intent) else {
            return nil
        }
        let requestedKeys = safeResourceKeys(keys, intent: intent)
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: requestedKeys,
            options: mask,
            errorHandler: errorHandler
        ) else {
            return nil
        }
        return FilteringDirectoryEnumerator(base: enumerator) { child in
            shouldSkip(child, intent: intent)
        }
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

    private func safeResourceKeys(
        _ keys: [URLResourceKey]?,
        intent: HostFileAccessIntent
    ) -> [URLResourceKey]? {
        switch intent {
        case .implicitScan:
            return nil
        case .explicitUserSelection, .astraManagedStorage:
            return keys
        }
    }
}

private final class FilteringDirectoryEnumerator: FileManager.DirectoryEnumerator {
    private let base: FileManager.DirectoryEnumerator
    private let shouldSkip: (URL) -> Bool

    public init(
        base: FileManager.DirectoryEnumerator,
        shouldSkip: @escaping (URL) -> Bool
    ) {
        self.base = base
        self.shouldSkip = shouldSkip
        super.init()
    }

    override var fileAttributes: [FileAttributeKey: Any]? {
        base.fileAttributes
    }

    override var directoryAttributes: [FileAttributeKey: Any]? {
        base.directoryAttributes
    }

    override var level: Int {
        base.level
    }

    override func nextObject() -> Any? {
        while let next = base.nextObject() {
            guard let url = next as? URL else {
                return next
            }
            if shouldSkip(url) {
                base.skipDescendants()
                continue
            }
            return url
        }
        return nil
    }

    override func skipDescendants() {
        base.skipDescendants()
    }

    override func skipDescendents() {
        base.skipDescendents()
    }
}
