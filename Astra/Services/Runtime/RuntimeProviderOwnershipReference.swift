import Darwin
import Foundation
import SwiftData

/// A protected pointer to the journal, never a second termination receipt.
/// The stable per-key kernel lock covers every read and replacement here.
struct RuntimeProviderOwnershipReference: Codable, Equatable, Sendable {
    let journalRoot: String
    let taskID: UUID
    let ownerID: UUID
    var taskOwnerID: PersistentIdentifier? = nil

    private func record() throws -> RuntimeExecutionOwnerRecord {
        var info = stat()
        guard journalRoot.hasPrefix("/"), lstat(journalRoot, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw RuntimeExecutionOwnerStore.Failure.unreadable
        }
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: journalRoot))
        let record: RuntimeExecutionOwnerRecord
        let records = try store.records().filter { $0.taskID == taskID }
        let matches: [RuntimeExecutionOwnerRecord]
        if let taskOwnerID {
            // Follow this row's journal across generations, including a
            // legacy file kept in place for an already-launched SSH helper.
            matches = records.filter { $0.taskOwnerID == taskOwnerID }
        } else {
            matches = records.filter { $0.ownerID == ownerID || $0.legacyReferenceOwnerID == ownerID }
        }
        guard matches.count == 1, let match = matches.first else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        record = match
        return record
    }

    static func handoff(at url: URL, key: AgentRuntimeSharedStateKey, to next: Self?,
                        prepare: () throws -> Void = {}) throws {
        if let previous = try read(url) {
            let record = try previous.record()
            // Admission of a successor under the same task journal has already
            // verified the previous generation. Only that admitted owner may
            // replace its own pointer while the new journal is unreleased.
            let sameJournalOwner = next?.journalRoot == previous.journalRoot
                && next?.taskID == previous.taskID && next?.taskOwnerID == record.taskOwnerID
                && next?.ownerID == record.ownerID

            guard sameJournalOwner || record.resourcesReleased == true
                    || record.providerSharedStateReleased == true || record.canRecoverPreparation else {
                throw RuntimeProviderResourceRegistry.Block(key: key, record: record)
            }
        }
        try prepare()
        if let next {
            let record = try next.record()
            guard record.ownerID == next.ownerID, record.providerSharedStateKey == key.rawValue,
                  record.cancellationRequested != true else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try save(next, at: url)
        } else if unlink(url.path) != 0 && errno != ENOENT {
            throw RuntimeExecutionOwnerStore.Failure.writeFailed
        }
    }

    private static func read(_ url: URL) throws -> Self? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw RuntimeExecutionOwnerStore.Failure.unreadable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size > 0, info.st_size < 4096 else {
            throw RuntimeExecutionOwnerStore.Failure.unreadable
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        do { return try JSONDecoder().decode(Self.self, from: Data(bytes)) }
        catch { throw RuntimeExecutionOwnerStore.Failure.unreadable }
    }

    private static func save(_ reference: Self, at url: URL) throws {
        let data = try JSONEncoder().encode(reference)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
        defer { close(fd); unlink(temporary.path) }
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw RuntimeExecutionOwnerStore.Failure.writeFailed
        }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
    }
}
