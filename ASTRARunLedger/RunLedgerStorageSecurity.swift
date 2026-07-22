import ASTRACore
import Darwin
import Foundation

/// Owns filesystem trust checks and cross-process first-open serialization.
/// SQLite schema validation deliberately lives in `RunLedgerSchema`.
enum RunLedgerStorageSecurity {
    private static let inProcessInitializationLock = NSLock()

    enum Preparation: Equatable {
        case newlyCreated
        case recoverableIncomplete
        case existing(hasInitializationMarker: Bool)
    }

    private static let initializationMarkerSuffix = ".initializing"
    private static let exclusiveWriterLockFileName = "run-ledger.writer.lock"

    /// Creates/validates the dedicated directory and claims its writer lease
    /// before any SQLite connection is opened. Schema open can initialize or
    /// migrate a store, so acquiring the lease after `RunLedgerSchema.open`
    /// would allow a losing broker to commit those mutations before reporting
    /// an exclusivity conflict.
    static func acquireExclusiveWriterLockBeforeOpeningLedger(
        at databaseURL: URL,
        createIfMissing: Bool
    ) throws -> Int32 {
        try withInitializationLock(
            at: databaseURL,
            createIfMissing: createIfMissing
        ) {
            try acquireExclusiveWriterLock(
                directory: databaseURL.deletingLastPathComponent()
            )
        }
    }

    /// Claims the process-lifetime exclusive-writer lock for a ledger
    /// directory and returns the descriptor that holds it. The caller must
    /// keep the descriptor open for as long as writer exclusivity is required
    /// and release it with `releaseExclusiveWriterLock`. The kernel releases
    /// the lock automatically if the process dies, so a crashed broker never
    /// strands the ledger. `O_CLOEXEC` keeps spawned supervisors and providers
    /// from inheriting the held lock. Fails immediately (`LOCK_NB`) instead of
    /// queueing behind a live holder: a second broker must exit, not wait.
    static func acquireExclusiveWriterLock(directory: URL) throws -> Int32 {
        try validateExistingPathComponents(directory)
        try validateDedicatedDirectory(directory)
        let lockPath = directory.appendingPathComponent(
            exclusiveWriterLockFileName, isDirectory: false
        ).path
        let descriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not open exclusive-writer lock file: \(posixError())"
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            throw RunLedgerError.unsafeStorage(
                "Could not inspect exclusive-writer lock file: \(posixError())"
            )
        }
        do {
            try validateArtifact(status, path: lockPath, requireSecureMode: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            let heldElsewhere = errno == EWOULDBLOCK
            Darwin.close(descriptor)
            if heldElsewhere {
                throw RunLedgerError.exclusiveWriterConflict(
                    "Another process already holds the exclusive ledger writer lock"
                )
            }
            throw RunLedgerError.unsafeStorage(
                "Could not acquire exclusive-writer lock: \(posixError())"
            )
        }
        return descriptor
    }

    static func releaseExclusiveWriterLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static func withInitializationLock<T>(
        at databaseURL: URL,
        createIfMissing: Bool,
        _ body: () throws -> T
    ) throws -> T {
        inProcessInitializationLock.lock()
        defer { inProcessInitializationLock.unlock() }
        guard databaseURL.isFileURL, databaseURL.path.hasPrefix("/") else {
            throw RunLedgerError.unsafeStorage("RunLedger requires an absolute file URL")
        }
        let directory = databaseURL.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        try validateExistingPathComponents(parent)

        if try pathStatus(directory.path) == nil {
            guard createIfMissing else { throw RunLedgerError.missingLedger }
            if Darwin.mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
                throw RunLedgerError.unsafeStorage(
                    "Could not create dedicated ledger directory: \(posixError())"
                )
            }
        }
        try validateExistingPathComponents(directory)
        try validateDedicatedDirectory(directory)

        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not open dedicated ledger directory without following links: \(posixError())"
            )
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              isDirectory(openedStatus),
              openedStatus.st_uid == getuid(),
              openedStatus.st_mode & 0o077 == 0 else {
            throw RunLedgerError.unsafeStorage("Opened ledger directory failed private ownership checks")
        }
        guard let pathStatus = try pathStatus(directory.path),
              pathStatus.st_dev == openedStatus.st_dev,
              pathStatus.st_ino == openedStatus.st_ino else {
            throw RunLedgerError.unsafeStorage("Ledger directory changed while acquiring its lock")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw RunLedgerError.unsafeStorage(
                "Could not acquire ledger initialization lock: \(posixError())"
            )
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func prepareStorage(
        at databaseURL: URL,
        installationID: RunBrokerInstallationID,
        createIfMissing: Bool,
        initializationCrashPoint: RunLedgerInitializationCrashPoint?
    ) throws -> Preparation {
        let directory = databaseURL.deletingLastPathComponent()
        try validateDedicatedDirectory(directory)

        let mainStatus = try pathStatus(databaseURL.path)
        let sidecarPaths = [databaseURL.path + "-wal", databaseURL.path + "-shm"]
        let markerPath = initializationMarkerPath(for: databaseURL)
        let markerStatus = try pathStatus(markerPath)
        if let markerStatus {
            try validateArtifact(markerStatus, path: markerPath, requireSecureMode: true)
            guard try Data(contentsOf: URL(fileURLWithPath: markerPath))
                    == initializationMarkerData(installationID: installationID) else {
                throw RunLedgerError.corrupt(
                    "Ledger initialization marker does not match this installation"
                )
            }
        }
        if let mainStatus {
            try validateArtifact(mainStatus, path: databaseURL.path, requireSecureMode: true)
            for sidecar in sidecarPaths {
                if let status = try pathStatus(sidecar) {
                    try validateArtifact(status, path: sidecar, requireSecureMode: true)
                }
            }
            if mainStatus.st_size == 0 {
                guard markerStatus != nil, createIfMissing else {
                    throw RunLedgerError.corrupt(
                        "Unclaimed empty ledger file cannot be adopted"
                    )
                }
                for sidecar in sidecarPaths where try pathStatus(sidecar) != nil {
                    throw RunLedgerError.corrupt("Empty interrupted ledger has SQLite sidecars")
                }
                return .recoverableIncomplete
            }
            let header = try Data(contentsOf: databaseURL, options: [.mappedIfSafe]).prefix(16)
            guard header == Data("SQLite format 3\0".utf8) else {
                throw RunLedgerError.corrupt("Ledger does not have a valid SQLite header")
            }
            return .existing(hasInitializationMarker: markerStatus != nil)
        } else {
            for sidecar in sidecarPaths {
                if let status = try pathStatus(sidecar) {
                    if isSymbolicLink(status) {
                        throw RunLedgerError.unsafeStorage("Ledger sidecar is a symbolic link: \(sidecar)")
                    }
                    throw RunLedgerError.corrupt("Ledger main file is missing while a sidecar remains")
                }
            }
            guard createIfMissing else { throw RunLedgerError.missingLedger }
            if markerStatus == nil {
                try createInitializationMarker(
                    at: markerPath,
                    installationID: installationID,
                    directory: directory
                )
                _ = RunLedgerInitializationCrash.trigger(
                    .afterInitializationMarkerCreated,
                    requested: initializationCrashPoint
                )
            }
            let descriptor = Darwin.open(
                databaseURL.path,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw RunLedgerError.unsafeStorage(
                    "Could not create ledger file without following links: \(posixError())"
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                throw RunLedgerError.unsafeStorage("Could not close newly created ledger file")
            }
            try synchronizeDirectory(directory)
            return markerStatus == nil ? .newlyCreated : .recoverableIncomplete
        }
    }

    static func secureArtifacts(at databaseURL: URL) throws {
        try validateDedicatedDirectory(databaseURL.deletingLastPathComponent())
        for path in [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
        ]
            where try pathStatus(path) != nil {
            try secureOwnedArtifact(path)
        }
    }

    static func completeInitialization(at databaseURL: URL) throws {
        let markerPath = initializationMarkerPath(for: databaseURL)
        guard let status = try pathStatus(markerPath) else { return }
        try validateArtifact(status, path: markerPath, requireSecureMode: true)
        guard Darwin.unlink(markerPath) == 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not remove completed ledger initialization marker: \(posixError())"
            )
        }
        try synchronizeDirectory(databaseURL.deletingLastPathComponent())
    }

    static func initializationMarkerURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: initializationMarkerPath(for: databaseURL))
    }

    private static func createInitializationMarker(
        at path: String,
        installationID: RunBrokerInstallationID,
        directory: URL
    ) throws {
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not create ledger initialization marker: \(posixError())"
            )
        }
        do {
            let data = initializationMarkerData(installationID: installationID)
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: written),
                        bytes.count - written
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else {
                        throw RunLedgerError.unsafeStorage(
                            "Could not write ledger initialization marker: \(posixError())"
                        )
                    }
                    written += result
                }
            }
            guard fsync(descriptor) == 0 else {
                throw RunLedgerError.unsafeStorage(
                    "Could not synchronize ledger initialization marker: \(posixError())"
                )
            }
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(path)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw RunLedgerError.unsafeStorage("Could not close ledger initialization marker")
        }
        try synchronizeDirectory(directory)
    }

    private static func initializationMarkerData(
        installationID: RunBrokerInstallationID
    ) -> Data {
        Data(
            "ASTRA RunLedger initialization v1\n\(installationID.rawValue.uuidString.lowercased())\n".utf8
        )
    }

    private static func initializationMarkerPath(for databaseURL: URL) -> String {
        databaseURL.path + initializationMarkerSuffix
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not open ledger directory for synchronization: \(posixError())"
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not synchronize ledger directory: \(posixError())"
            )
        }
    }

    private static func validateExistingPathComponents(_ url: URL) throws {
        var path = ""
        for component in url.path.split(separator: "/") {
            path += "/" + component
            guard let status = try pathStatus(path) else {
                throw RunLedgerError.unsafeStorage("Ledger path component is missing: \(path)")
            }
            guard (!isSymbolicLink(status) && isDirectory(status))
                    || isTrustedSystemDirectoryAlias(path, status: status) else {
                throw RunLedgerError.unsafeStorage(
                    "Ledger path component is not a no-follow directory: \(path)"
                )
            }
        }
    }

    private static func validateDedicatedDirectory(_ url: URL) throws {
        guard let status = try pathStatus(url.path),
              isDirectory(status),
              !isSymbolicLink(status) else {
            throw RunLedgerError.unsafeStorage("Dedicated ledger directory is not a real directory")
        }
        guard status.st_uid == getuid() else {
            throw RunLedgerError.unsafeStorage("Dedicated ledger directory is owned by another user")
        }
        let mode = status.st_mode & 0o777
        guard mode & 0o077 == 0, mode & 0o700 == 0o700 else {
            throw RunLedgerError.unsafeStorage(
                "Dedicated ledger directory must already be private mode 0700"
            )
        }
    }

    private static func secureOwnedArtifact(_ path: String) throws {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunLedgerError.unsafeStorage(
                "Could not open ledger artifact without following links: \(posixError())"
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw RunLedgerError.unsafeStorage("Could not inspect open ledger artifact")
        }
        try validateArtifact(status, path: path, requireSecureMode: false)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw RunLedgerError.unsafeStorage("Could not secure ledger artifact permissions")
        }
    }

    private static func validateArtifact(
        _ status: stat,
        path: String,
        requireSecureMode: Bool
    ) throws {
        guard isRegularFile(status), !isSymbolicLink(status) else {
            throw RunLedgerError.unsafeStorage("Ledger artifact is not a regular no-follow file: \(path)")
        }
        guard status.st_uid == getuid() else {
            throw RunLedgerError.unsafeStorage("Ledger artifact is owned by another user: \(path)")
        }
        guard status.st_nlink == 1 else {
            throw RunLedgerError.unsafeStorage("Ledger artifact has multiple hard links: \(path)")
        }
        if requireSecureMode {
            let mode = status.st_mode & 0o777
            guard mode & 0o077 == 0, mode & 0o600 == 0o600 else {
                throw RunLedgerError.unsafeStorage("Ledger artifact permissions are not private: \(path)")
            }
        }
    }

    private static func pathStatus(_ path: String) throws -> stat? {
        var value = stat()
        if lstat(path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw RunLedgerError.unsafeStorage("Could not inspect \(path): \(posixError())")
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func isSymbolicLink(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFLNK
    }

    /// macOS ships root-owned aliases into `/private`; no workspace-controlled
    /// symlink is accepted as a ledger ancestor.
    private static func isTrustedSystemDirectoryAlias(_ path: String, status: stat) -> Bool {
        guard isSymbolicLink(status), status.st_uid == 0 else { return false }
        let allowedDestinations: [String: Set<String>] = [
            "/tmp": ["private/tmp", "/private/tmp"],
            "/var": ["private/var", "/private/var"],
            "/etc": ["private/etc", "/private/etc"],
        ]
        guard let allowed = allowedDestinations[path],
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return false
        }
        return allowed.contains(destination)
    }

    private static func posixError() -> String {
        String(cString: strerror(errno))
    }
}
