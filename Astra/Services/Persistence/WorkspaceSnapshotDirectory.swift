import Darwin
import Foundation
import ASTRACore

/// Snapshot directories are a derived cache beside the protected source store.
/// The parent lock closes the create-before-lease window across processes;
/// each directory's kernel lease then protects it for the whole read. A crash
/// releases that lease without relying on Swift defer or a stale PID file.
enum WorkspaceSnapshotDirectory {
    private static let prefix = ".astra-mirror-"

    /// A short saving-actor fence may suspend while this immutable copy stays
    /// leased. Its capture and row traversal still run on the reader actor.
    final class Reservation {
        let root: URL
        private let lease: FileLease
        fileprivate init(root: URL, lease: FileLease) { self.root = root; self.lease = lease }
        deinit { try? FileManager.default.removeItem(at: root); lease.release() }
    }

    static func reserve(beside store: URL) throws -> Reservation {
        let parent = store.deletingLastPathComponent()
        let root: URL
        let lease: FileLease
        do {
            let parentLease = try FileLease(parent.appendingPathComponent(".astra-mirror-cleanup.lock"), blocking: true)
            defer { parentLease.release() }
            try reapAbandoned(in: parent)
            root = parent.appendingPathComponent(prefix + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            do { lease = try FileLease(root.appendingPathComponent("owner.lock"), blocking: true) }
            catch { try? FileManager.default.removeItem(at: root); throw error }
        }
        return Reservation(root: root, lease: lease)
    }

    private static func reapAbandoned(in parent: URL) throws {
        let manager = FileManager.default
        for root in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            let name = root.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            do {
                // Legacy snapshots have no lease file. Reclaim only known
                // snapshot artifacts (including interrupted SQLite backups),
                // never similarly named directories containing user files.
                let contents = try manager.contentsOfDirectory(atPath: root.path)
                let files: Set<String> = ["owner.lock", "snapshot.store", "snapshot.store-wal",
                    "snapshot.store-shm", "snapshot.store-journal"]
                guard contents.allSatisfy({ files.contains($0) || ($0.hasPrefix(".migration-")
                    && UUID(uuidString: String($0.dropFirst(".migration-".count))) != nil) }) else { continue }
                let lease = try FileLease(root.appendingPathComponent("owner.lock"), blocking: false)
                defer { lease.release() }
                try manager.removeItem(at: root)
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence",
                    fields: ["result": "orphan_snapshot_removed"], level: .debug)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && [EWOULDBLOCK, EAGAIN].contains(Int32(error.code)) {
                continue // A different projection still owns this copy.
            } catch {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence",
                    fields: ["result": "orphan_snapshot_cleanup_failed", "error_type": String(describing: type(of: error))],
                    level: .warning)
            }
        }
    }

    fileprivate final class FileLease {
        private var descriptor: Int32

        init(_ url: URL, blocking: Bool) throws {
            descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var result: Int32
            repeat { result = flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) }
            while result != 0 && errno == EINTR
            guard result == 0 else {
                let code = errno
                close(descriptor); descriptor = -1
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }

        func release() {
            guard descriptor >= 0 else { return }
            close(descriptor); descriptor = -1
        }

        deinit { release() }
    }
}
