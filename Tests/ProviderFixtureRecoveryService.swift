import CryptoKit
import Darwin
import Foundation
@testable import ASTRA

/// Isolated recovery rehearsal, deliberately test-only. It cannot open a
/// pre-existing namespace or recover a reservation from the user's app.
/// A legacy fixture without captured provenance/full stop evidence stays held.
final class ProviderFixtureRecoveryService {
    let root: URL
    let profile: URL
    private let directory: ProviderSharedStateDirectory
    fileprivate struct LockIdentity: Codable, Equatable {
        let device: dev_t
        let inode: ino_t
        let createdSeconds: Int
        let createdNanoseconds: Int
    }
    struct Ticket {
        fileprivate let key: AgentRuntimeSharedStateKey
        fileprivate let reference: RuntimeProviderOwnershipReference
        fileprivate let record: RuntimeExecutionOwnerRecord
        fileprivate let pointer: URL
        fileprivate let pointerBytes: Data
        fileprivate let journalBytes: Data
        fileprivate let audit: URL
        fileprivate let taskLock: LockIdentity
    }
    enum Outcome { case retired, alreadyRetired }
    enum Failure: Error { case unverified }

    init() throws {
        let fixture = try ProviderCoordinationFixture()
        root = fixture.coordination
        profile = fixture.data
        _ = try ProviderSharedStateDirectory(root.deletingLastPathComponent())
        guard mkdir(root.path, 0o700) == 0 else { throw Failure.unverified }
        directory = try ProviderSharedStateDirectory(root)
    }

    /// Called while constructing the synthetic fixture, before it is lost.
    /// The ticket binds exact bytes/IDs; a path prefix alone is never provenance.
    func capture(key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference) throws -> Ticket {
        try directory.verifyLocation()
        guard key.filePath == nil, reference.journalRoot == root.appendingPathComponent("journals").path else { throw Failure.unverified }
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot))
        let journal = try store.acquire(taskID: reference.taskID, taskOwnerID: reference.taskOwnerID)
        defer { withExtendedLifetime(journal) {} }
        let taskLock = try journalIdentity(journal)
        guard let record = try journal.read(), record.ownerID == reference.ownerID,
              record.providerSharedStateKey == key.rawValue else { throw Failure.unverified }
        let hash = SHA256.hash(data: Data(key.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let pointer = root.appendingPathComponent(hash + ".json")
        let bytes = try protectedBytes(pointer)
        guard try JSONDecoder().decode(RuntimeProviderOwnershipReference.self, from: bytes) == reference else { throw Failure.unverified }
        let ticket = Ticket(key: key, reference: reference, record: record, pointer: pointer,
            pointerBytes: bytes, journalBytes: try protectedBytes(journal.recordURL),
            audit: root.appendingPathComponent(hash + ".retired"), taskLock: taskLock)
        // Provenance is immutable and survives the rehearsal process ending.
        try writeAudit(ticket, at: root.appendingPathComponent(hash + ".fixture"))
        return ticket
    }

    func retire(_ ticket: Ticket, afterProviderLock: () throws -> Void = {}) async throws -> Outcome {
        try directory.verifyLocation()
        guard ticket.pointer.deletingLastPathComponent().path == root.path else { throw Failure.unverified }
        let lock = try await ProviderSharedStateProcessLock.acquire(ticket.key, root: root)
        defer { withExtendedLifetime(lock) {} }
        try afterProviderLock()
        try directory.verifyLocation()
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: ticket.reference.journalRoot))
        let journal = try store.acquire(taskID: ticket.reference.taskID, taskOwnerID: ticket.reference.taskOwnerID)
        defer { withExtendedLifetime(journal) {} }
        guard try journalIdentity(journal) == ticket.taskLock else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        guard try journal.read() == ticket.record, try protectedBytes(journal.recordURL) == ticket.journalBytes,
              ticket.record.appProcess.presence == .absent,
              ticket.record.providerProcess?.presence == .absent,
              ticket.record.state == .stopped || ticket.record.state == .finished,
              ticket.record.canReplace, ticket.record.retainedExecutionHead == nil,
              ticket.record.retainedProviderSharedStateKeys?.isEmpty != false,
              ticket.record.settlementInProgress == false,
              ticket.record.settlementLocalWorkStopped == true, ticket.record.settlementToolsStopped == true else {
            throw Failure.unverified
        }
        let evidence = try auditBytes(ticket)
        guard try protectedBytes(ticket.pointer.deletingPathExtension().appendingPathExtension("fixture")) == evidence else {
            throw Failure.unverified
        }
        var info = stat()
        if fstatat(directory.descriptor, ticket.pointer.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, try protectedBytes(ticket.audit) == evidence else { throw Failure.unverified }
            return .alreadyRetired
        }
        guard try protectedBytes(ticket.pointer) == ticket.pointerBytes else { throw Failure.unverified }
        try writeAudit(ticket, at: ticket.audit)
        try directory.verifyLocation()
        guard try journalIdentity(journal) == ticket.taskLock else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        guard unlinkat(directory.descriptor, ticket.pointer.lastPathComponent, 0) == 0 else { throw Failure.unverified }
        guard fsync(directory.descriptor) == 0 else { throw Failure.unverified }
        return .retired
    }

    private func journalIdentity(_ lease: RuntimeExecutionOwnerStore.Lease) throws -> LockIdentity {
        let journals = openat(directory.descriptor, "journals", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard journals >= 0 else { throw Failure.unverified }
        defer { close(journals) }
        let file = try lease.verifiedTaskLock(in: journals)
        return .init(device: file.st_dev, inode: file.st_ino, createdSeconds: file.st_birthtimespec.tv_sec,
                     createdNanoseconds: file.st_birthtimespec.tv_nsec)
    }

    private func auditBytes(_ ticket: Ticket) throws -> Data {
        struct Audit: Encodable {
            let source = "synthetic-fixture-recovery-rehearsal"
            let reference: RuntimeProviderOwnershipReference
            let executionID: UUID
            let pointer: Data
            let journal: Data
            let taskLock: LockIdentity
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Audit(reference: ticket.reference, executionID: ticket.record.executionID,
            pointer: ticket.pointerBytes, journal: ticket.journalBytes, taskLock: ticket.taskLock))
    }

    private func writeAudit(_ ticket: Ticket, at url: URL) throws {
        let bytes = try auditBytes(ticket)
        let fd = openat(directory.descriptor, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 {
            guard errno == EEXIST, try protectedBytes(url) == bytes else { throw Failure.unverified }
            return
        }
        defer { close(fd) }
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count, fsync(fd) == 0 else {
            throw Failure.unverified
        }
        guard fsync(directory.descriptor) == 0 else { throw Failure.unverified }
    }

    private func protectedBytes(_ url: URL) throws -> Data {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let fd: Int32
        if url.deletingLastPathComponent().path == root.path {
            fd = openat(directory.descriptor, url.lastPathComponent, flags)
        } else {
            guard url.deletingLastPathComponent().path == root.appendingPathComponent("journals").path else { throw Failure.unverified }
            let journals = openat(directory.descriptor, "journals", flags | O_DIRECTORY)
            guard journals >= 0 else { throw Failure.unverified }
            fd = openat(journals, url.lastPathComponent, flags)
            close(journals)
        }
        guard fd >= 0 else { throw Failure.unverified }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size < 65_536 else {
            throw Failure.unverified
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count else { throw Failure.unverified }
        return Data(bytes)
    }
}
