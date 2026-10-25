import CryptoKit
import Darwin
import Foundation

/// Utilities and task providers serialize the same physical settings file,
/// including when two ASTRA instances have separate actor gates.
final class ProviderSharedStateProcessLock: @unchecked Sendable {
    private let descriptor: Int32
    private let referenceURL: URL
    private init(_ descriptor: Int32, referenceURL: URL) {
        self.descriptor = descriptor; self.referenceURL = referenceURL
    }
    func handoff(_ key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference?,
                 prepare: () throws -> Void) throws {
        try RuntimeProviderOwnershipReference.handoff(at: referenceURL, key: key, to: reference, prepare: prepare)
    }
    deinit { close(descriptor) }

    static func acquire(_ key: AgentRuntimeSharedStateKey, root override: URL? = nil) async throws -> ProviderSharedStateProcessLock {
        let root = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASTRA Runtime Coordination/provider-state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        let name = SHA256.hash(data: Data(key.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let fd = open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        let lease = ProviderSharedStateProcessLock(fd, referenceURL: root.appendingPathComponent(name + ".json"))
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        while true {
            try Task.checkCancellation()
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return lease }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
