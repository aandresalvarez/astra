import CryptoKit
import Darwin
import Foundation
import ASTRACore

/// Utilities and task providers serialize the same physical settings file,
/// including when two ASTRA instances have separate actor gates.
final class ProviderSharedStateProcessLock: @unchecked Sendable {
    private let descriptor: Int32
    private let directory: ProviderSharedStateDirectory
    private let referenceName: String
    private init(_ descriptor: Int32, directory: ProviderSharedStateDirectory, referenceName: String) {
        self.descriptor = descriptor; self.directory = directory; self.referenceName = referenceName
    }
    func handoff(_ key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference?,
                 prepare: () throws -> Void) throws {
        do {
            try RuntimeProviderOwnershipReference.handoff(in: directory, name: referenceName, key: key, to: reference, prepare: prepare)
        } catch RuntimeExecutionOwnerStore.Failure.unreadable, RuntimeExecutionOwnerStore.Failure.unsafePath {
            throw ProviderSharedStateCompatibility.UnreadableReservation(path: directory.url.appendingPathComponent(referenceName).path)
        }
    }
    deinit { close(descriptor) }

    static func acquire(_ key: AgentRuntimeSharedStateKey, root override: URL? = nil, deadline: ContinuousClock.Instant? = nil,
                        reference: RuntimeProviderOwnershipReference? = nil) async throws -> ProviderSharedStateProcessLock {
        let root = try ProviderSharedStateNamespace.resolve(override: override, key: key)
        let directory = try ProviderSharedStateDirectory(root)
        // Swift keys compare canonical Unicode equivalents as equal. Use the same
        // equivalence for physical lock bytes; legacy names must remain exact.
        let identity = key.filePath == nil ? key.rawValue : key.rawValue.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = (key.filePath == nil ? "" : "file-v1-") + hash
        let fd = openat(directory.descriptor, name, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        let lease = ProviderSharedStateProcessLock(fd, directory: directory, referenceName: name + ".json")
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        while true {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw RuntimeProviderStateWaitTimeout() }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                if key.filePath != nil {
                    try await ProviderSharedStateCompatibility.waitForLegacyLocks(in: directory, deadline: deadline)
                    try await ProviderSharedStateCompatibility.checkLegacyReferences(in: directory, key: key, reference: reference, deadline: deadline)
                }
                return lease
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
