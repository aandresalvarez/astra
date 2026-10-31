import Darwin
import Foundation

/// Compatibility reads only: never rename, unlink or reinterpret old locks or
/// journals. An opaque legacy lock cannot prove which physical file it owns.
enum ProviderSharedStateCompatibility {
    struct UnreadableReservation: LocalizedError {
        let path: String
        var errorDescription: String? {
            "The provider did not start. A shared-configuration reservation cannot be verified because its lock or ownership record is missing, unreadable or unsafe. ASTRA preserved it; a missing record is not proof that the execution and tools stopped. Review this reservation before retrying: \(path)"
        }
    }
    private static func isLegacyLock(_ name: String) -> Bool {
        name.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func waitForLegacyLocks(in directory: ProviderSharedStateDirectory, deadline: ContinuousClock.Instant?, onContention: @Sendable () -> Void = {}) async throws {
        for name in try directory.names() where isLegacyLock(name) {
            let url = directory.url.appendingPathComponent(name)
            let fd = openat(directory.descriptor, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw UnreadableReservation(path: url.path) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
                throw UnreadableReservation(path: url.path)
            }
            while true {
                try Task.checkCancellation()
                if let deadline, ContinuousClock.now >= deadline { throw RuntimeProviderStateWaitTimeout() }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw UnreadableReservation(path: url.path) }
                onContention()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func checkLegacyReferences(in directory: ProviderSharedStateDirectory, key: AgentRuntimeSharedStateKey,
                                reference: RuntimeProviderOwnershipReference?, deadline: ContinuousClock.Instant?) async throws {
        for name in try directory.names() where name.hasSuffix(".json") && isLegacyLock(String(name.dropLast(5))) {
            let url = directory.url.appendingPathComponent(name)
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw RuntimeProviderStateWaitTimeout() }
            do { try RuntimeProviderOwnershipReference.assertCompatible(in: directory, name: name, key: key, next: reference) }
            catch let block as RuntimeProviderResourceRegistry.Block { throw block }
            catch { throw UnreadableReservation(path: url.path) }
        }
    }
}
