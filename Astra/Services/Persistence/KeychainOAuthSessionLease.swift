import Darwin
import Foundation
import os

/// Shared by refresh, generation copy and deletion in the dedicated vault.
/// Holding this lease across an await prevents a late OAuth response from
/// recreating a session whose deletion was already declared complete.
public final class KeychainOAuthSessionLease: @unchecked Sendable {
    public enum Failure: Error { case busy, unavailable }
    private static let active = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let descriptor: Int32
    private let key: String

    private init(descriptor: Int32, key: String) { self.descriptor = descriptor; self.key = key }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
        Self.active.withLock { _ = $0.remove(key) }
    }

    public static func acquire(namespaceID: UUID) throws -> KeychainOAuthSessionLease {
        guard !AstraSecureKeychainStore.shouldBlockUnscopedTestKeychainAccess else { throw Failure.unavailable }
        let root = AstraSecureKeychainStore.oauthSessionLockDirectory
        let key = root.path + "/" + namespaceID.uuidString
        guard active.withLock({ $0.insert(key).inserted }) else { throw Failure.busy }
        var held = false
        defer { if !held { active.withLock { _ = $0.remove(key) } } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unavailable }
        let fd = openat(directory, namespaceID.uuidString + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0 else { close(fd); throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? Failure.busy : Failure.unavailable
        }
        held = true
        return KeychainOAuthSessionLease(descriptor: fd, key: key)
    }
}
