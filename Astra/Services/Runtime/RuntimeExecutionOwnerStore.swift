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
        func saveWorkspaceContinuation(_ authorization: RuntimeWorkspaceContinuationAuthorization) throws {
            guard authorization.taskID == taskID, authorization.taskOwnerID == taskOwnerID,
                  !authorization.sources.isEmpty else { throw Failure.unreadable }
            let directory = recordURL.deletingLastPathComponent()
            let entries = try RuntimeExecutionOwnerStore.workspaceContinuationEntries(root: directory, create: true)
            var next: UUID?
            // Publish the small header last. A crash leaves only unreachable
            // entries, never a partial authorization. Each entry retains the
            // journal's size bound without limiting the number of predecessors.
            for source in authorization.sources.reversed() {
                let entry = WorkspaceContinuationEntry(source: source, next: next)
                guard try JSONEncoder().encode(entry).count <= 32_768 else { throw Failure.unreadable }
                let id = UUID()
                try save(entry, at: entries.appendingPathComponent(id.uuidString + ".handoffentry"))
                next = id
            }
            let header = WorkspaceContinuationHeader(taskID: authorization.taskID, taskOwnerID: authorization.taskOwnerID,
                requestID: authorization.requestID, sourceEventID: authorization.sourceEventID,
                approvedAt: authorization.approvedAt, count: authorization.sources.count, head: next!,
                workspaceScope: authorization.workspaceScope, inheritedAuthorizationID: authorization.inheritedAuthorizationID)
            try save(header, at: directory.appendingPathComponent(authorization.requestID.uuidString + ".handoff"))
        }
        private func save<T: Encodable>(_ record: T, at recordURL: URL) throws {
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

    /// Called only under the task lease, before publishing a successor. A
    /// crash between these writes retains the old authority; retry is idempotent.
    func retain(_ record: RuntimeExecutionOwnerRecord) throws {
        let directory = retainedDirectory(taskID: record.taskID, ownerID: record.ownerID)
        try validateRetainedDirectory(taskID: record.taskID, ownerID: record.ownerID, create: true)
        let url = directory.appendingPathComponent(record.executionID.uuidString + ".json")
        if let existing = try Self.read(url) {
            // A pre-upgrade crash may have retained this exact receipt before
            // publishing its successor. Binding the current legacy journal must
            // not rewrite or invalidate that immutable, still-unattributed copy.
            var attributed = existing
            if attributed.taskOwnerID == nil { attributed.taskOwnerID = record.taskOwnerID }
            guard attributed == record else { throw Failure.unreadable }
            return
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafePath }
        // Lease owns the descriptor and performs the same atomic, synced write
        // as the current journal. Admission already holds the per-task lock.
        let writer = Lease(descriptor: fd, recordURL: url, taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try writer.save(record)
    }

    func retainedExecutions(of record: RuntimeExecutionOwnerRecord) throws -> [RuntimeExecutionOwnerRecord] {
        var result: [RuntimeExecutionOwnerRecord] = []
        var head = record.retainedExecutionHead
        if head != nil { try validateRetainedDirectory(taskID: record.taskID, ownerID: record.ownerID, create: false) }
        var seen: Set<UUID> = [record.executionID]
        while let id = head {
            guard seen.insert(id).inserted,
                  let previous = try Self.read(retainedDirectory(taskID: record.taskID, ownerID: record.ownerID)
                    .appendingPathComponent(id.uuidString + ".json")),
                  previous.taskID == record.taskID, previous.ownerID == record.ownerID,
                  previous.taskOwnerID == nil || previous.taskOwnerID == record.taskOwnerID,
                  previous.executionID == id else { throw Failure.unreadable }
            result.append(previous); head = previous.retainedExecutionHead
        }
        return result
    }

    private func validateRetainedDirectory(taskID: UUID, ownerID: UUID, create: Bool) throws {
        var path = root
        for component in ["", "retained", taskID.uuidString, ownerID.uuidString] {
            if !component.isEmpty { path.appendPathComponent(component) }
            if create && !component.isEmpty {
                guard mkdir(path.path, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafePath }
            }
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        }
    }

    private func retainedDirectory(taskID: UUID, ownerID: UUID) -> URL {
        root.appendingPathComponent("retained").appendingPathComponent(taskID.uuidString)
            .appendingPathComponent(ownerID.uuidString)
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
    private struct WorkspaceContinuationHeader: Codable {
        let taskID: UUID
        let taskOwnerID: PersistentIdentifier
        let requestID: UUID
        let sourceEventID: UUID
        let approvedAt: Date
        let count: Int
        let head: UUID
        var workspaceScope: RuntimeWorkspaceContinuationAuthorization.WorkspaceScope? = nil
        var inheritedAuthorizationID: UUID? = nil
    }
    private struct WorkspaceContinuationEntry: Codable {
        let source: RuntimeWorkspaceContinuationAuthorization.Source
        let next: UUID?
    }

    private static func workspaceContinuationEntries(root: URL, create: Bool) throws -> URL {
        let directory = root.appendingPathComponent("workspace-continuations")
        if create {
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafePath }
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        return directory
    }

    func workspaceContinuation(requestID: UUID) throws -> RuntimeWorkspaceContinuationAuthorization? {
        guard let header: WorkspaceContinuationHeader = try Self.readValue(root.appendingPathComponent(requestID.uuidString + ".handoff")) else { return nil }
        guard header.requestID == requestID, header.count > 0 else { throw Failure.unreadable }
        let entries = try Self.workspaceContinuationEntries(root: root, create: false)
        var sources: [RuntimeWorkspaceContinuationAuthorization.Source] = []
        var visited = Set<UUID>()
        var next: UUID? = header.head
        while let id = next {
            guard sources.count < header.count, visited.insert(id).inserted,
                  let entry: WorkspaceContinuationEntry = try Self.readValue(entries.appendingPathComponent(id.uuidString + ".handoffentry")) else { throw Failure.unreadable }
            sources.append(entry.source); next = entry.next
        }
        guard sources.count == header.count else { throw Failure.unreadable }
        return .init(taskID: header.taskID, taskOwnerID: header.taskOwnerID, requestID: header.requestID,
            sourceEventID: header.sourceEventID, approvedAt: header.approvedAt, sources: sources,
            workspaceScope: header.workspaceScope, inheritedAuthorizationID: header.inheritedAuthorizationID)
    }

    func workspaceAuthorizations(workspaceOwnerID: PersistentIdentifier) throws -> [RuntimeWorkspaceContinuationAuthorization] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "handoff" }.compactMap { url in
                guard let header: WorkspaceContinuationHeader = try Self.readValue(url),
                      header.workspaceScope?.workspaceOwnerID == workspaceOwnerID,
                      header.inheritedAuthorizationID == nil,
                      url.lastPathComponent == header.requestID.uuidString + ".handoff" else { return nil }
                return try workspaceContinuation(requestID: header.requestID)
            }.sorted { $0.approvedAt > $1.approvedAt }
    }

    static func read(_ url: URL) throws -> RuntimeExecutionOwnerRecord? { try readValue(url) }

    private static func readValue<T: Decodable>(_ url: URL) throws -> T? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unreadable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 32_768 else { throw Failure.unreadable }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { throw Failure.unreadable }
        do { return try JSONDecoder().decode(T.self, from: Data(bytes)) }
        catch { throw Failure.unreadable }
    }
}
