import Darwin
import Foundation
import ASTRACore

enum PortablePackageFileError: Error, Equatable {
    case invalidPath
    case missing
    case notRegularFile
    case tooLarge(actual: Int, maximum: Int)
}

enum PortablePackageStagingError: Error, Equatable {
    case containsSymlink(String)
    case tooManyFiles(limit: Int)
    case tooLarge(limit: Int)
    case copyFailed(String)
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
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else { return false }
        // Reject traversal only when a whole path *component* is `..` — a
        // substring check would also reject legitimate filenames containing
        // consecutive dots, e.g. an embedded app/capability ID like
        // `com.example..tool` that `WorkspaceAppIDPolicy` and the capability
        // package-ID validator both permit.
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0 == ".." || $0 == "." || $0.isEmpty }
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

    /// Walks the package tree once (POSIX `lstat`, no follow) to enforce the
    /// review budget *before* any hashing: returns an error if a symlink is
    /// present anywhere, the regular-file count exceeds `maxFileCount`, or the
    /// aggregate size exceeds `maxTotalBytes`. Reads nothing — bounds the work
    /// synchronous validation does on an untrusted package so a crafted huge or
    /// many-file tree can't hash-hang the UI before a blocker is shown, and
    /// surfaces the same symlink rejection `stageBoundedCopy` applies at import
    /// as a pre-confirmation blocker.
    static func reviewBoundsViolation(
        in rootURL: URL,
        maxFileCount: Int = 10_000,
        maxTotalBytes: Int = 500 * 1024 * 1024
    ) -> PortablePackageStagingError? {
        var rootStat = stat()
        if lstat(rootURL.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFLNK {
            return .containsSymlink(rootURL.lastPathComponent)
        }
        var remainingFiles = maxFileCount
        var remainingBytes = maxTotalBytes
        return boundsWalk(
            dirPath: rootURL.path,
            relativePrefix: "",
            maxFileCount: maxFileCount,
            maxTotalBytes: maxTotalBytes,
            remainingFiles: &remainingFiles,
            remainingBytes: &remainingBytes
        )
    }

    private static func boundsWalk(
        dirPath: String,
        relativePrefix: String,
        maxFileCount: Int,
        maxTotalBytes: Int,
        remainingFiles: inout Int,
        remainingBytes: inout Int
    ) -> PortablePackageStagingError? {
        guard let dir = opendir(dirPath) else { return nil }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: Array(raw.bindMemory(to: CChar.self)))
            }
            if name == "." || name == ".." { continue }
            let childPath = "\(dirPath)/\(name)"
            let childRelative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            var childStat = stat()
            guard lstat(childPath, &childStat) == 0 else { continue }
            switch childStat.st_mode & S_IFMT {
            case S_IFLNK:
                return .containsSymlink(childRelative)
            case S_IFDIR:
                if let violation = boundsWalk(
                    dirPath: childPath,
                    relativePrefix: childRelative,
                    maxFileCount: maxFileCount,
                    maxTotalBytes: maxTotalBytes,
                    remainingFiles: &remainingFiles,
                    remainingBytes: &remainingBytes
                ) {
                    return violation
                }
            case S_IFREG:
                remainingFiles -= 1
                if remainingFiles < 0 { return .tooManyFiles(limit: maxFileCount) }
                remainingBytes -= Int(childStat.st_size)
                if remainingBytes < 0 { return .tooLarge(limit: maxTotalBytes) }
            default:
                continue
            }
        }
        return nil
    }

    /// Copies `sourceURL` into `destinationURL` as a private, self-contained
    /// snapshot, refusing any symbolic link and enforcing a file-count and
    /// aggregate-byte budget *as it walks* — never a bare `copyItem` of the
    /// whole tree. A reviewed package sitting in a writable location could be
    /// swapped for a huge or link-laden tree before confirmation; an unbounded
    /// recursive copy would burn temp disk and block the main actor before the
    /// fingerprint check could reject it, and per-file size limits alone don't
    /// stop a package of many individually-permitted files. POSIX `lstat` walk
    /// (matches `firstSymlink`), so links are detected without being followed.
    static func stageBoundedCopy(
        from sourceURL: URL,
        to destinationURL: URL,
        maxFileCount: Int = 10_000,
        maxTotalBytes: Int = 500 * 1024 * 1024,
        fileManager: FileManager = .default
    ) throws {
        var rootStat = stat()
        if lstat(sourceURL.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFLNK {
            throw PortablePackageStagingError.containsSymlink(sourceURL.lastPathComponent)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        // Open the root as a directory descriptor with O_NOFOLLOW; the whole walk
        // then resolves children RELATIVE to directory descriptors (openat/fstatat
        // with O_NOFOLLOW), never by reopening a path by name — so a directory
        // that passed lstat as S_IFDIR cannot be swapped for a symlink and
        // followed out of the package between check and open.
        let rootFD = Darwin.open(sourceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw PortablePackageStagingError.copyFailed(sourceURL.lastPathComponent) }
        var remainingFiles = maxFileCount
        var remainingBytes = maxTotalBytes
        // copyBounded takes ownership of rootFD (closed via fdopendir/closedir).
        try copyBounded(
            sourceDirFD: rootFD,
            toDirectory: destinationURL.path,
            relativePrefix: "",
            maxFileCount: maxFileCount,
            maxTotalBytes: maxTotalBytes,
            remainingFiles: &remainingFiles,
            remainingBytes: &remainingBytes,
            fileManager: fileManager
        )
    }

    /// Copies the directory referenced by `sourceDirFD` (ownership transferred:
    /// closed here). Children are stat'd with `fstatat(..., AT_SYMLINK_NOFOLLOW)`
    /// and opened with `openat(..., O_NOFOLLOW)` relative to the directory
    /// descriptor, so no path component is ever re-resolved by name — closing the
    /// TOCTOU where a checked directory child is replaced by a symlink before the
    /// recursive descent.
    private static func copyBounded(
        sourceDirFD: Int32,
        toDirectory destinationPath: String,
        relativePrefix: String,
        maxFileCount: Int,
        maxTotalBytes: Int,
        remainingFiles: inout Int,
        remainingBytes: inout Int,
        fileManager: FileManager
    ) throws {
        // fdopendir adopts sourceDirFD; closedir closes it. openat/fstatat on the
        // same fd only use it as a resolution base and don't disturb readdir.
        guard let dir = fdopendir(sourceDirFD) else {
            close(sourceDirFD)
            throw PortablePackageStagingError.copyFailed(relativePrefix.isEmpty ? "." : relativePrefix)
        }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: Array(raw.bindMemory(to: CChar.self)))
            }
            if name == "." || name == ".." { continue }
            let childDestination = "\(destinationPath)/\(name)"
            let childRelative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            var childStat = stat()
            guard fstatat(sourceDirFD, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch childStat.st_mode & S_IFMT {
            case S_IFLNK:
                throw PortablePackageStagingError.containsSymlink(childRelative)
            case S_IFDIR:
                let childFD = openat(sourceDirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard childFD >= 0 else { throw PortablePackageStagingError.copyFailed(childRelative) }
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: childDestination, isDirectory: true),
                    withIntermediateDirectories: true
                )
                try copyBounded(
                    sourceDirFD: childFD,
                    toDirectory: childDestination,
                    relativePrefix: childRelative,
                    maxFileCount: maxFileCount,
                    maxTotalBytes: maxTotalBytes,
                    remainingFiles: &remainingFiles,
                    remainingBytes: &remainingBytes,
                    fileManager: fileManager
                )
            case S_IFREG:
                remainingFiles -= 1
                guard remainingFiles >= 0 else {
                    throw PortablePackageStagingError.tooManyFiles(limit: maxFileCount)
                }
                // Open the file relative to the directory fd with O_NOFOLLOW, so a
                // symlink swapped in after the fstatat fails the open. The pre-copy
                // `st_size` is advisory only (the source is still attacker-writable),
                // so stream and enforce the *remaining* byte budget on bytes
                // actually read — a mid-copy growth is rejected before it can burn
                // arbitrary temp disk.
                let fileFD = openat(sourceDirFD, name, O_RDONLY | O_NOFOLLOW)
                guard fileFD >= 0 else { throw PortablePackageStagingError.copyFailed(childRelative) }
                let copied = try copyRegularFileBounded(
                    sourceFD: fileFD,
                    label: childRelative,
                    toPath: childDestination,
                    maxBytes: remainingBytes,
                    totalLimit: maxTotalBytes
                )
                remainingBytes -= copied
            default:
                // Skip anything that is not a directory or a regular file
                // (fifos, sockets, devices have no place in a package).
                continue
            }
        }
    }

    /// Streams the already-open, no-follow source descriptor `sourceFD`
    /// (ownership transferred: closed here) to `destinationPath`, copying at most
    /// `maxBytes` and returning the number of bytes written. Reading stops the
    /// instant the byte budget is exceeded — the copy is bounded by bytes
    /// actually read, never a pre-measured `st_size`.
    private static func copyRegularFileBounded(
        sourceFD: Int32,
        label: String,
        toPath destinationPath: String,
        maxBytes: Int,
        totalLimit: Int
    ) throws -> Int {
        defer { close(sourceFD) }
        var sourceStat = stat()
        guard fstat(sourceFD, &sourceStat) == 0,
              (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw PortablePackageStagingError.copyFailed(label)
        }
        let destFD = Darwin.open(destinationPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard destFD >= 0 else { throw PortablePackageStagingError.copyFailed(destinationPath) }
        defer { close(destFD) }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var total = 0
        while true {
            let readCount = read(sourceFD, &buffer, bufferSize)
            if readCount < 0 { throw PortablePackageStagingError.copyFailed(label) }
            if readCount == 0 { break }
            total += readCount
            guard total <= maxBytes else {
                throw PortablePackageStagingError.tooLarge(limit: totalLimit)
            }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes { raw in
                    Darwin.write(destFD, raw.baseAddress!.advanced(by: written), readCount - written)
                }
                if writeCount <= 0 { throw PortablePackageStagingError.copyFailed(destinationPath) }
                written += writeCount
            }
        }
        return total
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
