import Darwin
import Foundation
import ASTRACore

enum PortablePackageFileError: Error, Equatable {
    case invalidPath
    case missing
    case notRegularFile
    case tooLarge(actual: Int, maximum: Int)
}

/// Safe file access for reading an untrusted, portable package bundle.
///
/// Opens each path one component at a time via `openat(..., O_NOFOLLOW)`, so a
/// symlink planted at any intermediate path component — not just the leaf —
/// can't redirect a read outside the package root. Generalizes the pattern
/// `WorkspaceAppPackageService.openContainedPackageFile` already uses for
/// `.astra-app` packages (`WorkspaceAppPackageService.swift:1406-1441`), kept
/// as an independent utility rather than a modification to that file.
enum PortablePackageSafeFileReader {
    static let defaultMaximumFileBytes = 10 * 1024 * 1024

    static func isPortableRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("..")
            && !path.contains("\\")
            && !path.contains("\0")
    }

    /// Returns the relative path of the first symbolic link found anywhere in
    /// `rootURL` — including the root itself — or `nil` if the tree contains
    /// none. Uses `lstat` so links are detected without ever being followed;
    /// a caller that has just copied an untrusted package into a private
    /// staging directory can use this to prove the copy is a self-contained
    /// snapshot (no entry aliases a location the source can still rewrite).
    /// POSIX-based to match this type's existing no-follow file access — and
    /// deliberately not routed through a directory-listing broker, whose
    /// symlink-resolving containment filter would hide the very out-of-root
    /// links this needs to surface.
    static func firstSymlink(in rootURL: URL) -> String? {
        let rootPath = rootURL.path
        var rootStat = stat()
        if lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFLNK {
            return rootURL.lastPathComponent
        }
        return firstSymlink(inDirectory: rootPath, relativePrefix: "")
    }

    private static func firstSymlink(inDirectory dirPath: String, relativePrefix: String) -> String? {
        guard let dir = opendir(dirPath) else { return nil }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: Array(bytes))
            }
            if name == "." || name == ".." { continue }
            let childPath = "\(dirPath)/\(name)"
            let childRelative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            var childStat = stat()
            guard lstat(childPath, &childStat) == 0 else { continue }
            let mode = childStat.st_mode & S_IFMT
            if mode == S_IFLNK { return childRelative }
            if mode == S_IFDIR, let found = firstSymlink(inDirectory: childPath, relativePrefix: childRelative) {
                return found
            }
        }
        return nil
    }

    static func openSafeDescriptor(rootURL: URL, relativePath: String) throws -> Int32 {
        guard isPortableRelativePath(relativePath) else { throw PortablePackageFileError.invalidPath }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw PortablePackageFileError.invalidPath }

        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        var current = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY)
        guard current >= 0 else {
            throw errno == ENOENT ? PortablePackageFileError.missing : PortablePackageFileError.invalidPath
        }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = isLast
                ? (O_RDONLY | O_NOFOLLOW)
                : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            let next = component.withCString { Darwin.openat(current, $0, flags) }
            let openErrno = errno
            close(current)
            guard next >= 0 else {
                throw openErrno == ENOENT ? PortablePackageFileError.missing : PortablePackageFileError.invalidPath
            }
            current = next
        }

        var fileStat = stat()
        guard fstat(current, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG else {
            close(current)
            throw PortablePackageFileError.notRegularFile
        }
        return current
    }

    static func readData(
        rootURL: URL,
        relativePath: String,
        maximumBytes: Int = defaultMaximumFileBytes
    ) throws -> Data {
        let descriptor = try openSafeDescriptor(rootURL: rootURL, relativePath: relativePath)
        defer { close(descriptor) }

        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else { throw PortablePackageFileError.invalidPath }
        let size = Int(statBuffer.st_size)
        guard size <= maximumBytes else {
            throw PortablePackageFileError.tooLarge(actual: size, maximum: maximumBytes)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                let updated = data.count + count
                guard updated <= maximumBytes else {
                    throw PortablePackageFileError.tooLarge(actual: updated, maximum: maximumBytes)
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw PortablePackageFileError.invalidPath
            }
        }
    }

    static func digest(
        rootURL: URL,
        relativePath: String,
        maximumBytes: Int = defaultMaximumFileBytes
    ) throws -> String {
        WorkspaceAppService.digest(for: try readData(rootURL: rootURL, relativePath: relativePath, maximumBytes: maximumBytes))
    }

    /// Every regular, non-symlink file under `rootURL`, as paths relative to
    /// it. Shared by the exporter (to build `checksums.json`) and the
    /// validator (to confirm every present file is listed in it), so the two
    /// can't independently drift on what counts as a portable file. Symlink
    /// defense here is leaf-level only (matches `.astra-app`'s own
    /// enumeration) — actual byte reads of any returned path still go
    /// through the O_NOFOLLOW-safe walk above.
    ///
    /// Enumerates through `HostFileAccessBroker` rather than a raw
    /// `FileManager.enumerator`, matching this codebase's convention for
    /// every persistence-adjacent filesystem scan (architecture-fitness
    /// enforces this per-file, e.g. `WorkspaceImportDiscovery.swift`).
    static func portableFilePaths(
        in rootURL: URL,
        intent: HostFileAccessIntent,
        fileManager: FileManager = .default
    ) -> [String] {
        let broker = HostFileAccessBroker(fileManager: fileManager)
        guard let enumerator = broker.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            intent: intent
        ) else {
            return []
        }
        let basePath = rootURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isDirectory != true, values?.isSymbolicLink != true, values?.isRegularFile == true else {
                return nil
            }
            let filePath = url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard filePath.hasPrefix("\(basePath)/") else { return nil }
            return String(filePath.dropFirst(basePath.count + 1))
        }
        .sorted()
    }
}
