import Darwin
import Foundation
import SwiftData
import CryptoKit

/// Protected, local launch authority. Task events are its audit projection,
/// never a second admission owner; imported workspace JSON cannot grant a lease.
/// A stable flock serializes readers/writers and is held for the whole worker.
final class RuntimeExecutionOwnerStore {
    let root: URL
    init(root: URL) { self.root = root }

    enum Failure: Error { case busy, unsafePath, unreadable, writeFailed }
    final class Lease {
        private var descriptor: Int32
        private(set) var recordURL: URL
        private let taskID: UUID
        private let taskOwnerID: PersistentIdentifier?
        init(descriptor: Int32, recordURL: URL, taskID: UUID, taskOwnerID: PersistentIdentifier?) {
            self.taskID = taskID; self.descriptor = descriptor; self.recordURL = recordURL; self.taskOwnerID = taskOwnerID
        }
        deinit { close(descriptor) }
        func read() throws -> RuntimeExecutionOwnerRecord? {
            let record = try RuntimeExecutionOwnerStore.read(recordURL)
            guard record == nil || (record?.taskID == taskID && (taskOwnerID == nil || record?.taskOwnerID == taskOwnerID)) else {
                throw Failure.unreadable
            }
            return record
        }
        func save(_ record: RuntimeExecutionOwnerRecord) throws {
            var record = record
            guard record.taskID == taskID, taskOwnerID == nil || record.taskOwnerID == nil || record.taskOwnerID == taskOwnerID else { throw Failure.unreadable }
            record.taskOwnerID = taskOwnerID ?? record.taskOwnerID
            try save(record, at: recordURL)
        }
        private func save(_ record: RuntimeExecutionOwnerRecord, at recordURL: URL) throws {
            let data = try JSONEncoder().encode(record)
            let temporary = recordURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw Failure.writeFailed }
            defer { close(fd); unlink(temporary.path) }
            let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard wrote == data.count, fsync(fd) == 0, rename(temporary.path, recordURL.path) == 0 else { throw Failure.writeFailed }
            let parent = open(recordURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parent >= 0 else { throw Failure.writeFailed }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw Failure.writeFailed }
        }

        /// Attribute in place: remote helpers may already hold this receipt
        /// path. Moving it would strand cancellation/observation after upgrade.
        func bindLegacy(_ legacy: RuntimeExecutionOwnerRecord) throws {
            guard let taskOwnerID, try read() == nil else { throw Failure.unreadable }
            let legacyURL = recordURL.deletingLastPathComponent().appendingPathComponent(legacy.taskID.uuidString + ".json")
            guard try RuntimeExecutionOwnerStore.read(legacyURL) == legacy else { throw Failure.unreadable }
            var bound = legacy
            bound.taskOwnerID = taskOwnerID
            try save(bound, at: legacyURL)
            recordURL = legacyURL
        }

    }

    func acquire(taskID: UUID, taskOwnerID: PersistentIdentifier? = nil) throws -> Lease {
        let targetURL = try recordURL(taskID, owner: taskOwnerID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        let lockURL = root.appendingPathComponent(taskID.uuidString + ".lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unsafePath }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            close(fd); throw Failure.unsafePath
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        // Keep the portable-ID lock across scoped copies, including old apps.
        return Lease(descriptor: fd, recordURL: targetURL, taskID: taskID, taskOwnerID: taskOwnerID)
    }

    /// Serializes conflict inspection and journal publication across app instances.
    /// This lease is short lived; the per-task lease remains held during work.
    func acquireAdmission() throws -> Lease {
        try acquire(taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }

    func records() throws -> [RuntimeExecutionOwnerRecord] {
        let entries: [URL]
        do { entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        // Only an absent scan root is empty. Missing or corrupt enumerated
        // receipts still fail closed, as do protected provider references.
        return try entries.filter { $0.pathExtension == "json" }.map { url in
                guard let record = try Self.read(url) else { throw Failure.unreadable }
                let scopedURL = try recordURL(record.taskID, owner: record.taskOwnerID)
                let legacyURL = try recordURL(record.taskID, owner: nil)
                guard url.lastPathComponent == scopedURL.lastPathComponent || url.lastPathComponent == legacyURL.lastPathComponent else { throw Failure.unreadable }
                return record
            }
    }

    func read(taskID: UUID, taskOwnerID: PersistentIdentifier? = nil) throws -> RuntimeExecutionOwnerRecord? {
        let record = try Self.read(recordURL(taskID, owner: taskOwnerID))
        guard record == nil || (record?.taskID == taskID && (taskOwnerID == nil || record?.taskOwnerID == taskOwnerID)) else {
            throw Failure.unreadable
        }
        return record
    }
    private func recordURL(_ id: UUID, owner: PersistentIdentifier?) throws -> URL {
        guard let owner else { return root.appendingPathComponent(id.uuidString + ".json") }
        guard owner.storeIdentifier != nil else { throw Failure.unreadable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(owner)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(id.uuidString + "-" + digest + ".json")
    }
    private static func read(_ url: URL) throws -> RuntimeExecutionOwnerRecord? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unreadable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 32_768 else { throw Failure.unreadable }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { throw Failure.unreadable }
        do { return try JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: Data(bytes)) }
        catch { throw Failure.unreadable }
    }
}
