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
        /// Verify the actual held lock when a caller also owns a pinned journal directory.
        func verifiedTaskLock(in directory: Int32) throws -> stat {
            var held = stat(), named = stat()
            guard fstat(descriptor, &held) == 0,
                  fstatat(directory, taskID.uuidString + ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw Failure.unsafePath }
            return held
        }
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
            for original in authorization.sources.reversed() {
                var source = original
                var jobHead: UUID?
                if let jobs = source.reviewedSSHJobs, !jobs.isEmpty {
                    // Every identity is retained. Small pages also bound a single
                    // protected read when one predecessor has thousands of jobs.
                    for offset in stride(from: ((jobs.count - 1) / 32) * 32, through: 0, by: -32) {
                        let page = WorkspaceContinuationJobPage(jobs: Array(jobs[offset..<min(offset + 32, jobs.count)]), next: jobHead)
                        let id = UUID()
                        try save(page, at: entries.appendingPathComponent(id.uuidString + ".handoffjobs"))
                        jobHead = id
                    }
                    source.reviewedSSHJobs = nil
                }
                let entry = WorkspaceContinuationEntry(source: source, next: next,
                    reviewedJobCount: jobHead == nil ? nil : original.reviewedSSHJobs?.count, reviewedJobHead: jobHead)
                guard try JSONEncoder().encode(entry).count <= 32_768 else { throw Failure.unreadable }
                let id = UUID()
                try save(entry, at: entries.appendingPathComponent(id.uuidString + ".handoffentry"))
                next = id
            }
            let header = WorkspaceContinuationHeader(taskID: authorization.taskID, taskOwnerID: authorization.taskOwnerID,
                requestID: authorization.requestID, sourceEventID: authorization.sourceEventID,
                approvedAt: authorization.approvedAt, count: authorization.sources.count, head: next!,
                workspaceScope: authorization.workspaceScope, inheritedAuthorizationID: authorization.inheritedAuthorizationID,
                beneficiaryReceiptDigest: authorization.beneficiaryReceiptDigest)
            try save(header, at: directory.appendingPathComponent(authorization.requestID.uuidString + ".handoff"))
        }
        private func save<T: Encodable>(_ record: T, at recordURL: URL) throws {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 32_768 else { throw Failure.unreadable }
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

        func saveReconciliation(from original: RuntimeExecutionOwnerRecord, to reconciled: RuntimeExecutionOwnerRecord) throws -> RuntimeExecutionOwnerRecord {
            guard try read() == original, original.taskID == reconciled.taskID,
                  original.taskOwnerID == reconciled.taskOwnerID, original.ownerID == reconciled.ownerID,
                  original.executionID == reconciled.executionID, original.runID == reconciled.runID,
                  reconciled.resourcesReleased == true, reconciled.canReplace else { throw Failure.unreadable }
            let directory = try RuntimeExecutionOwnerStore.reconciliations(root: recordURL.deletingLastPathComponent(), create: true)
            let url = directory.appendingPathComponent(original.executionID.uuidString + ".release")
            let entry = ExecutionReconciliation(originalDigest: try RuntimeExecutionOwnerStore.receiptDigest(original), reconciled: reconciled)
            var published = reconciled
            if let existing: ExecutionReconciliation = try RuntimeExecutionOwnerStore.readValue(url) {
                var retry = entry.reconciled
                retry.updatedAt = existing.reconciled.updatedAt
                guard existing.originalDigest == entry.originalDigest, existing.reconciled == retry else { throw Failure.unreadable }
                published = existing.reconciled
            } else {
                try save(entry, at: url)
            }
            try save(published)
            return published
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

    func acquire(taskID: UUID, taskOwnerID: PersistentIdentifier? = nil, createIfMissing: Bool = true) throws -> Lease {
        let targetURL = try recordURL(taskID, owner: taskOwnerID)
        if createIfMissing {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        let lockURL = root.appendingPathComponent(taskID.uuidString + ".lock")
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
        let fd = open(lockURL.path, flags, 0o600)
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
            guard try attributed == record || reconciledRecord(attributed) == record else { throw Failure.unreadable }
            return
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafePath }
        // Lease owns the descriptor and performs the same atomic, synced write
        // as the current journal. Admission already holds the per-task lock.
        let writer = Lease(descriptor: fd, recordURL: url, taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try writer.save(record)
    }

    func retainedExecutions(of record: RuntimeExecutionOwnerRecord,
                            read: (URL) throws -> RuntimeExecutionOwnerRecord? = RuntimeExecutionOwnerStore.read) throws -> [RuntimeExecutionOwnerRecord] {
        var result: [RuntimeExecutionOwnerRecord] = []
        var head = record.retainedExecutionHead
        if head != nil { try validateRetainedDirectory(taskID: record.taskID, ownerID: record.ownerID, create: false) }
        var seen: Set<UUID> = [record.executionID]
        while let id = head {
            guard seen.insert(id).inserted,
                  let previous = try read(retainedDirectory(taskID: record.taskID, ownerID: record.ownerID)
                    .appendingPathComponent(id.uuidString + ".json")),
                  previous.taskID == record.taskID, previous.ownerID == record.ownerID,
                  previous.taskOwnerID == nil || previous.taskOwnerID == record.taskOwnerID,
                  previous.executionID == id else { throw Failure.unreadable }
            let effective = try reconciledRecord(previous)
            guard effective.taskOwnerID == nil || effective.taskOwnerID == record.taskOwnerID else { throw Failure.unreadable }
            result.append(effective); head = previous.retainedExecutionHead
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
    private struct ExecutionReconciliation: Codable, Equatable {
        let originalDigest: String
        let reconciled: RuntimeExecutionOwnerRecord
    }

    static func receiptDigest(_ record: RuntimeExecutionOwnerRecord) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
    }

    /// Project a verified release without rewriting the immutable historical receipt.
    private func reconciledRecord(_ original: RuntimeExecutionOwnerRecord) throws -> RuntimeExecutionOwnerRecord {
        let directory = root.appendingPathComponent("reconciliations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return original }
        _ = try Self.reconciliations(root: root, create: false)
        guard let entry: ExecutionReconciliation = try Self.readValue(directory.appendingPathComponent(original.executionID.uuidString + ".release")) else { return original }
        var repaired = entry.reconciled
        var beforeAttribution = original
        if repaired.taskOwnerID == nil {
            beforeAttribution.taskOwnerID = nil
            repaired.taskOwnerID = original.taskOwnerID
        } else if original.taskOwnerID == nil {
            beforeAttribution.taskOwnerID = repaired.taskOwnerID
        }
        // The first archive can be made after release, or already contain the
        // pre-release receipt. Both project identically without rewriting either.
        if repaired == original { return original }
        guard repaired.taskID == original.taskID,
              repaired.taskOwnerID == (original.taskOwnerID ?? entry.reconciled.taskOwnerID),
              repaired.ownerID == original.ownerID, repaired.executionID == original.executionID,
              repaired.runID == original.runID, repaired.resourcesReleased == true, repaired.canReplace,
              try entry.originalDigest == Self.receiptDigest(beforeAttribution) else { throw Failure.unreadable }
        return repaired
    }

    private static func reconciliations(root: URL, create: Bool) throws -> URL {
        let directory = root.appendingPathComponent("reconciliations")
        if create { guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafePath } }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        return directory
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
        var beneficiaryReceiptDigest: String? = nil
    }
    private struct WorkspaceContinuationEntry: Codable {
        let source: RuntimeWorkspaceContinuationAuthorization.Source
        let next: UUID?
        var reviewedJobCount: Int? = nil
        var reviewedJobHead: UUID? = nil
    }
    private struct WorkspaceContinuationJobPage: Codable {
        let jobs: [ReviewedWorkspaceSSHJob]
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
            var source = entry.source
            if let count = entry.reviewedJobCount {
                guard count > 0, entry.reviewedJobHead != nil, source.reviewedSSHJobs == nil else { throw Failure.unreadable }
                var jobs: [ReviewedWorkspaceSSHJob] = []
                var visitedPages = Set<UUID>()
                var jobNext = entry.reviewedJobHead
                while let pageID = jobNext {
                    guard jobs.count < count, visitedPages.insert(pageID).inserted,
                          let page: WorkspaceContinuationJobPage = try Self.readValue(entries.appendingPathComponent(pageID.uuidString + ".handoffjobs")),
                          !page.jobs.isEmpty, page.jobs.count <= count - jobs.count else { throw Failure.unreadable }
                    jobs += page.jobs; jobNext = page.next
                }
                guard jobs.count == count,
                      Set(jobs.map { [$0.executionID, $0.jobID, $0.nonce] }).count == count else { throw Failure.unreadable }
                source.reviewedSSHJobs = jobs
            } else if entry.reviewedJobHead != nil { throw Failure.unreadable }
            sources.append(source); next = entry.next
        }
        guard sources.count == header.count else { throw Failure.unreadable }
        return .init(taskID: header.taskID, taskOwnerID: header.taskOwnerID, requestID: header.requestID,
            sourceEventID: header.sourceEventID, approvedAt: header.approvedAt, sources: sources,
            beneficiaryReceiptDigest: header.beneficiaryReceiptDigest, workspaceScope: header.workspaceScope, inheritedAuthorizationID: header.inheritedAuthorizationID)
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
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
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
