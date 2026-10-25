import Darwin
import Foundation

/// Protected, local launch authority. Task events are its audit projection,
/// never a second admission owner; imported workspace JSON cannot grant a lease.
/// A stable flock serializes readers/writers and is held for the whole worker.
final class RuntimeExecutionOwnerStore {
    let root: URL
    init(root: URL) { self.root = root }

    enum Failure: Error { case busy, unsafePath, unreadable, writeFailed }
    final class Lease {
        private var descriptor: Int32
        let recordURL: URL
        init(descriptor: Int32, recordURL: URL) { self.descriptor = descriptor; self.recordURL = recordURL }
        deinit { close(descriptor) }
        func read() throws -> RuntimeExecutionOwnerRecord? { try RuntimeExecutionOwnerStore.read(recordURL) }
        func save(_ record: RuntimeExecutionOwnerRecord) throws {
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
    }

    func acquire(taskID: UUID) throws -> Lease {
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
        return Lease(descriptor: fd, recordURL: recordURL(taskID))
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
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let record = try Self.read(url), record.taskID == id else { throw Failure.unreadable }
                return record
            }
    }

    func read(taskID: UUID) throws -> RuntimeExecutionOwnerRecord? { try Self.read(recordURL(taskID)) }
    private func recordURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
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
