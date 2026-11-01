import CryptoKit
import Darwin
import Foundation
import ASTRACore

/// Utilities and task providers serialize the same physical settings file,
/// including when two ASTRA instances have separate actor gates.
final class ProviderSharedStateProcessLock: @unchecked Sendable {
    private let descriptor: Int32
    private let directory: ProviderSharedStateDirectory
    private let lockName: String
    private init(_ descriptor: Int32, directory: ProviderSharedStateDirectory, lockName: String) {
        self.descriptor = descriptor; self.directory = directory; self.lockName = lockName
    }
    func handoff(_ key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference?,
                 prepare: () throws -> Void) throws {
        let referenceName = lockName + ".json"
        do {
            try RuntimeProviderOwnershipReference.handoff(in: directory, name: referenceName, key: key, to: reference,
                verifyLease: { _ = try self.verifiedFile(in: self.directory, named: self.lockName) }, prepare: prepare)
        } catch RuntimeExecutionOwnerStore.Failure.unreadable, RuntimeExecutionOwnerStore.Failure.unsafePath {
            throw ProviderSharedStateCompatibility.UnreadableReservation(path: directory.url.appendingPathComponent(referenceName).path)
        }
    }
    func verifiedFile(in directory: ProviderSharedStateDirectory, named name: String) throws -> stat {
        try directory.verifiedLock(descriptor, named: name)
    }

    func checkPreviousWriter(_ key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference?) throws {
        let name = lockName + ".json"
        do {
            _ = try verifiedFile(in: directory, named: lockName)
            try RuntimeProviderOwnershipReference.assertCompatible(in: directory, name: name, key: key, next: reference, reading: true, exactKey: true)
            _ = try verifiedFile(in: directory, named: lockName)
        } catch RuntimeExecutionOwnerStore.Failure.unreadable, RuntimeExecutionOwnerStore.Failure.unsafePath {
            throw ProviderSharedStateCompatibility.UnreadableReservation(path: directory.url.appendingPathComponent(name).path)
        }
    }

    deinit { close(descriptor) }

    static func acquire(_ key: AgentRuntimeSharedStateKey, root override: URL? = nil, deadline: ContinuousClock.Instant? = nil,
                        reference: RuntimeProviderOwnershipReference? = nil,
                        reading: Bool = false, matchingExistingLock: ((stat) -> Bool)? = nil) async throws -> ProviderSharedStateProcessLock {
        let root = try ProviderSharedStateNamespace.resolve(override: override, key: key)
        let directory = try ProviderSharedStateDirectory(root, createIfMissing: matchingExistingLock == nil)
        // Swift keys compare canonical Unicode equivalents as equal. Use the same
        // equivalence for physical lock bytes; legacy names must remain exact.
        let identity = key.filePath == nil ? key.rawValue : key.rawValue.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = (key.filePath == nil ? "" : "file-v1-") + hash
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (matchingExistingLock == nil ? O_CREAT : 0)
        let fd = openat(directory.descriptor, name, flags, 0o600)
        guard fd >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        let lease = ProviderSharedStateProcessLock(fd, directory: directory, lockName: name)
        while true {
            let file = try lease.verifiedFile(in: directory, named: name)
            if let matchingExistingLock, !matchingExistingLock(file) { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw RuntimeProviderStateWaitTimeout() }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                if key.filePath != nil {
                    try await ProviderSharedStateCompatibility.waitForLegacyLocks(in: directory, deadline: deadline)
                    try await ProviderSharedStateCompatibility.checkLegacyReferences(in: directory, key: key, reference: reference, deadline: deadline, reading: reading)
                }
                _ = try lease.verifiedFile(in: directory, named: name)
                return lease
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
