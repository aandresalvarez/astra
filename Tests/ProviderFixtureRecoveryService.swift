import CryptoKit
import Darwin
import Foundation
@testable import ASTRA

/// Isolated recovery rehearsal, deliberately test-only. It cannot open a
/// pre-existing namespace or recover a reservation from the user's app.
/// A legacy fixture without captured provenance/full stop evidence stays held.
final class ProviderFixtureRecoveryService {
    let root: URL
    struct Ticket {
        fileprivate let key: AgentRuntimeSharedStateKey
        fileprivate let reference: RuntimeProviderOwnershipReference
        fileprivate let record: RuntimeExecutionOwnerRecord
        fileprivate let pointer: URL
        fileprivate let pointerBytes: Data
        fileprivate let journalBytes: Data
        fileprivate let audit: URL
    }
    enum Outcome { case retired, alreadyRetired }
    enum Failure: Error { case unverified }

    init() throws {
        root = try ProviderSharedStateNamespace.resolve().appendingPathComponent("recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard mkdir(root.path, 0o700) == 0 else { throw Failure.unverified }
    }

    /// Called while constructing the synthetic fixture, before it is lost.
    /// The ticket binds exact bytes/IDs; a path prefix alone is never provenance.
    func capture(key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference) throws -> Ticket {
        guard key.filePath == nil, reference.journalRoot == root.appendingPathComponent("journals").path else { throw Failure.unverified }
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot))
        let journal = try store.acquire(taskID: reference.taskID, taskOwnerID: reference.taskOwnerID)
        guard let record = try journal.read(), record.ownerID == reference.ownerID,
              record.providerSharedStateKey == key.rawValue else { throw Failure.unverified }
        let hash = SHA256.hash(data: Data(key.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let pointer = root.appendingPathComponent(hash + ".json")
        let bytes = try protectedBytes(pointer)
        guard try JSONDecoder().decode(RuntimeProviderOwnershipReference.self, from: bytes) == reference else { throw Failure.unverified }
        let ticket = Ticket(key: key, reference: reference, record: record, pointer: pointer,
            pointerBytes: bytes, journalBytes: try protectedBytes(journal.recordURL),
            audit: root.appendingPathComponent(hash + ".retired"))
        // Provenance is immutable and survives the rehearsal process ending.
        try writeAudit(ticket, at: root.appendingPathComponent(hash + ".fixture"))
        return ticket
    }

    func retire(_ ticket: Ticket) async throws -> Outcome {
        guard ticket.pointer.deletingLastPathComponent().path == root.path else { throw Failure.unverified }
        let lock = try await ProviderSharedStateProcessLock.acquire(ticket.key, root: root)
        defer { withExtendedLifetime(lock) {} }
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: ticket.reference.journalRoot))
        let journal = try store.acquire(taskID: ticket.reference.taskID, taskOwnerID: ticket.reference.taskOwnerID)
        guard try journal.read() == ticket.record, try protectedBytes(journal.recordURL) == ticket.journalBytes,
              ticket.record.appProcess.presence == .absent,
              ticket.record.providerProcess?.presence == .absent,
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
        if access(ticket.pointer.path, F_OK) != 0 {
            guard errno == ENOENT, try protectedBytes(ticket.audit) == evidence else { throw Failure.unverified }
            return .alreadyRetired
        }
        guard try protectedBytes(ticket.pointer) == ticket.pointerBytes else { throw Failure.unverified }
        try writeAudit(ticket, at: ticket.audit)
        guard unlink(ticket.pointer.path) == 0 else { throw Failure.unverified }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unverified }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw Failure.unverified }
        return .retired
    }

    private func auditBytes(_ ticket: Ticket) throws -> Data {
        struct Audit: Encodable {
            let source = "synthetic-fixture-recovery-rehearsal"
            let reference: RuntimeProviderOwnershipReference
            let executionID: UUID
            let pointer: Data
            let journal: Data
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Audit(reference: ticket.reference, executionID: ticket.record.executionID,
            pointer: ticket.pointerBytes, journal: ticket.journalBytes))
    }

    private func writeAudit(_ ticket: Ticket, at url: URL) throws {
        let bytes = try auditBytes(ticket)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 {
            guard errno == EEXIST, try protectedBytes(url) == bytes else { throw Failure.unverified }
            return
        }
        defer { close(fd) }
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count, fsync(fd) == 0 else {
            throw Failure.unverified
        }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unverified }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw Failure.unverified }
    }

    private func protectedBytes(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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
