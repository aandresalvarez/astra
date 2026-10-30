import CryptoKit
import Darwin
import Foundation
import ASTRACore

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
        do {
            try RuntimeProviderOwnershipReference.handoff(at: referenceURL, key: key, to: reference, prepare: prepare)
        } catch RuntimeExecutionOwnerStore.Failure.unreadable, RuntimeExecutionOwnerStore.Failure.unsafePath {
            throw ProviderSharedStateCompatibility.UnreadableReservation(path: referenceURL.path)
        }
    }
    deinit { close(descriptor) }

    private static let defaultRoot: URL = {
        // SwiftPM fixtures must never leave fabricated reservations in the
        // user's real cross-app coordination namespace.
        if ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("astra-provider-tests-\(UUID().uuidString)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASTRA Runtime Coordination/provider-state", isDirectory: true)
    }()

    static func acquire(_ key: AgentRuntimeSharedStateKey, root override: URL? = nil, deadline: ContinuousClock.Instant? = nil,
                        reference: RuntimeProviderOwnershipReference? = nil) async throws -> ProviderSharedStateProcessLock {
        let root = override ?? defaultRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        // Swift keys compare canonical Unicode equivalents as equal. Use the same
        // equivalence for physical lock bytes; legacy names must remain exact.
        let identity = key.filePath == nil ? key.rawValue : key.rawValue.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = (key.filePath == nil ? "" : "file-v1-") + hash
        let fd = open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        let lease = ProviderSharedStateProcessLock(fd, referenceURL: root.appendingPathComponent(name + ".json"))
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        while true {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw RuntimeProviderStateWaitTimeout() }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                if key.filePath != nil { try await ProviderSharedStateCompatibility.waitForLegacyLocks(in: root, deadline: deadline) }
                if key.filePath != nil {
                    try await ProviderSharedStateCompatibility.checkLegacyReferences(in: root, key: key, reference: reference, deadline: deadline)
                }
                return lease
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
