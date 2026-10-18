import Foundation
import ASTRACore

/// Orders queued auto-export mirror writes against workspace deletion.
///
/// `autoExport` snapshots a workspace's config and writes it later, off the
/// main actor. A deletion that removes the mirror in between would have the
/// late write recreate it from the stale snapshot, and startup recovery could
/// then import the deleted workspace again. Each snapshot takes a ticket for
/// its workspace's current generation; `retire` moves the generation on,
/// waiting for a write already in progress, so every write queued before it
/// is dropped while exports taken after it, such as a reimport's, still land.
public final class WorkspaceAutoExportGate: @unchecked Sendable {
    public static let shared = WorkspaceAutoExportGate()

    public struct Ticket: Sendable {
        let workspaceID: String
        let generation: Int
        let coveredReadRevision: Int
        let preparedRead: ReadTicket?

        init(workspaceID: String, generation: Int, coveredReadRevision: Int, preparedRead: ReadTicket? = nil) {
            self.workspaceID = workspaceID
            self.generation = generation
            self.coveredReadRevision = coveredReadRevision
            self.preparedRead = preparedRead
        }
    }

    /// An explicit snapshot may replace prior work only after its file lands.
    struct ExplicitTicket: Sendable {
        let workspaceID: String
        let revision: Int
        let epoch: Int
        let coveredReadRevision: Int
    }

    /// Reading may fail or be superseded without revoking an already prepared
    /// value. Publication order advances only after its file replacement.
    struct ReadTicket: Sendable {
        let workspaceID: String
        let revision: Int
        let epoch: Int
    }

    private let lock = NSLock()
    // Publication order, source-read validity, destructive/explicit barriers,
    // and the newest published read are separate dimensions of the same gate.
    // A sealed older copy may finish until a replacement lands, and can never
    // cross a deletion, destination move, or a successful newer publication.
    private var generations: [String: Int] = [:]
    private var readRevisions: [String: Int] = [:]
    private var epochs: [String: Int] = [:]
    private var publishedReadRevisions: [String: Int] = [:]
    private var explicitRevisions: [String: Int] = [:]
    private var publishedExplicitRevisions: [String: Int] = [:]

    func reserveExport(for workspaceID: String) -> ExplicitTicket {
        lock.withLock {
            explicitRevisions[workspaceID, default: 0] += 1
            return ExplicitTicket(workspaceID: workspaceID, revision: explicitRevisions[workspaceID, default: 0],
                epoch: epochs[workspaceID, default: 0], coveredReadRevision: readRevisions[workspaceID, default: 0])
        }
    }

    func isCurrent(_ ticket: ExplicitTicket) -> Bool { lock.withLock { canPublish(ticket) } }

    private func canPublish(_ ticket: ExplicitTicket) -> Bool {
        epochs[ticket.workspaceID, default: 0] == ticket.epoch
            && publishedReadRevisions[ticket.workspaceID, default: 0] <= ticket.coveredReadRevision
            && publishedExplicitRevisions[ticket.workspaceID, default: 0] < ticket.revision
    }

    func readTicket(for workspaceID: String) -> ReadTicket {
        lock.withLock { ReadTicket(workspaceID: workspaceID, revision: readRevisions[workspaceID, default: 0],
            epoch: epochs[workspaceID, default: 0]) }
    }

    func beginRead(for workspaceID: String) -> ReadTicket {
        lock.withLock {
            readRevisions[workspaceID, default: 0] += 1
            return ReadTicket(workspaceID: workspaceID, revision: readRevisions[workspaceID, default: 0],
                epoch: epochs[workspaceID, default: 0])
        }
    }

    func isCurrent(_ ticket: ReadTicket) -> Bool {
        lock.withLock { readRevisions[ticket.workspaceID, default: 0] == ticket.revision
            && epochs[ticket.workspaceID, default: 0] == ticket.epoch
            && publishedReadRevisions[ticket.workspaceID, default: 0] < ticket.revision }
    }

    func isSealedCurrent(_ ticket: ReadTicket) -> Bool {
        lock.withLock { epochs[ticket.workspaceID, default: 0] == ticket.epoch
            && publishedReadRevisions[ticket.workspaceID, default: 0] < ticket.revision }
    }

    func invalidateIfCurrent(_ ticket: ReadTicket) {
        lock.withLock {
            guard readRevisions[ticket.workspaceID, default: 0] == ticket.revision,
                  epochs[ticket.workspaceID, default: 0] == ticket.epoch,
                  publishedReadRevisions[ticket.workspaceID, default: 0] < ticket.revision else { return }
            readRevisions[ticket.workspaceID, default: 0] += 1
        }
    }

    func promote(_ ticket: ReadTicket, sealed: Bool) -> Ticket? {
        lock.withLock {
            guard sealed || readRevisions[ticket.workspaceID, default: 0] == ticket.revision,
                  epochs[ticket.workspaceID, default: 0] == ticket.epoch,
                  publishedReadRevisions[ticket.workspaceID, default: 0] < ticket.revision else { return nil }
            return Ticket(workspaceID: ticket.workspaceID, generation: generations[ticket.workspaceID, default: 0],
                coveredReadRevision: ticket.revision, preparedRead: ticket)
        }
    }

    func retireIfCurrentEpoch(_ ticket: ReadTicket) {
        lock.withLock {
            guard epochs[ticket.workspaceID, default: 0] == ticket.epoch else { return }
            epochs[ticket.workspaceID, default: 0] += 1
            generations[ticket.workspaceID, default: 0] += 1
        }
    }

    public func ticket(for workspaceID: String) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        return Ticket(workspaceID: workspaceID, generation: generations[workspaceID, default: 0],
            coveredReadRevision: publishedReadRevisions[workspaceID, default: 0])
    }

    /// An explicit value snapshot is already prepared at this boundary.
    /// Supersede earlier reads and writes only after that preparation succeeds.
    public func beginExport(for workspaceID: String) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        generations[workspaceID, default: 0] += 1
        epochs[workspaceID, default: 0] += 1
        publishedReadRevisions[workspaceID] = readRevisions[workspaceID, default: 0]
        return Ticket(workspaceID: workspaceID, generation: generations[workspaceID, default: 0],
            coveredReadRevision: publishedReadRevisions[workspaceID, default: 0])
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return canPublish(ticket)
    }

    private func canPublish(_ ticket: Ticket) -> Bool {
        if let read = ticket.preparedRead {
            return epochs[read.workspaceID, default: 0] == read.epoch
                && publishedReadRevisions[read.workspaceID, default: 0] < read.revision
        }
        return generations[ticket.workspaceID, default: 0] == ticket.generation
    }

    /// Withdraw a prepared publication on a moved/deleted destination, without
    /// letting an older lease retire a newer explicit snapshot.
    func invalidateIfCurrent(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        guard canPublish(ticket) else { return }
        generations[ticket.workspaceID, default: 0] += 1
        epochs[ticket.workspaceID, default: 0] += 1
    }

    /// Writes `data` to `url` only while no `retire` came after `ticket`.
    /// The slow part, writing the bytes, happens outside the gate, into a
    /// temporary file beside `url`; the gate is held only to check the
    /// generation and rename that file into place, so a `retire` on the main
    /// actor never waits on a stalled volume, and no write lands after it.
    /// False when the write was dropped.
    func writeIfCurrent(_ ticket: Ticket, data: Data, to url: URL) throws -> Bool {
        try publishIfCurrent(ticket, data: data, to: url) != nil
    }

    func publishIfCurrent(_ ticket: Ticket, data: Data, to url: URL) throws -> Ticket? {
        try withStagedFile(data, to: url) { staging in
            lock.lock()
            defer { lock.unlock() }
            guard canPublish(ticket) else { return nil }
            try replace(staging, at: url)
            guard let read = ticket.preparedRead else { return ticket }
            generations[ticket.workspaceID, default: 0] += 1
            publishedReadRevisions[ticket.workspaceID] = read.revision
            return Ticket(workspaceID: ticket.workspaceID, generation: generations[ticket.workspaceID, default: 0],
                coveredReadRevision: read.revision)
        }
    }

    /// Renaming and superseding share the gate. A failed encoding, staging or
    /// rename leaves the old read/publication fully eligible as a fallback.
    func writeIfCurrent(_ ticket: ExplicitTicket, data: Data, to url: URL) throws -> Ticket? {
        try withStagedFile(data, to: url) { staging in
            lock.lock()
            defer { lock.unlock() }
            guard canPublish(ticket) else { return nil }
            try replace(staging, at: url)
            generations[ticket.workspaceID, default: 0] += 1
            publishedReadRevisions[ticket.workspaceID] = ticket.coveredReadRevision
            publishedExplicitRevisions[ticket.workspaceID] = ticket.revision
            return Ticket(workspaceID: ticket.workspaceID, generation: generations[ticket.workspaceID, default: 0],
                coveredReadRevision: ticket.coveredReadRevision)
        }
    }

    private func withStagedFile<T>(_ data: Data, to url: URL, publish: (URL) throws -> T) throws -> T {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).astra-export-\(UUID().uuidString)")
        try data.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try publish(staging)
    }

    private func replace(_ staging: URL, at url: URL) throws {
        guard Darwin.rename(staging.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Drops every mirror write queued for `workspaceID` so far. Call it
    /// before removing a deleted workspace's mirror.
    public func retire(workspaceID: String) {
        lock.lock()
        defer { lock.unlock() }
        generations[workspaceID, default: 0] += 1
        epochs[workspaceID, default: 0] += 1
    }
}

/// Serializes workspace auto-export JSON encode + file writes off the main actor.
///
/// Actor isolation guarantees that two auto-exports never write the same file
/// concurrently, and the `.atomic` write means `WorkspaceRecoveryService` /
/// `loadConfig` can never observe a torn file. Auto-export drops `.prettyPrinted`
/// (kept only for explicit user-facing exports via `WorkspaceConfigManager.write`)
/// while preserving `.sortedKeys` so the on-disk recovery file stays deterministic.
actor WorkspaceAutoExportWriter {
    static let shared = WorkspaceAutoExportWriter()
    private let beforeWrite: (@Sendable () async -> Void)?

    init(beforeWrite: (@Sendable () async -> Void)? = nil) { self.beforeWrite = beforeWrite }

    private enum Publication: Sendable {
        case prepared(WorkspaceAutoExportGate.Ticket)
        case explicit(WorkspaceAutoExportGate.ExplicitTicket)

        var isCurrent: Bool {
            switch self {
            case .prepared(let ticket): WorkspaceAutoExportGate.shared.isCurrent(ticket)
            case .explicit(let ticket): WorkspaceAutoExportGate.shared.isCurrent(ticket)
            }
        }

        func publish(_ data: Data, to url: URL) throws -> WorkspaceAutoExportGate.Ticket? {
            switch self {
            case .prepared(let ticket):
                return try WorkspaceAutoExportGate.shared.publishIfCurrent(ticket, data: data, to: url)
            case .explicit(let ticket):
                return try WorkspaceAutoExportGate.shared.writeIfCurrent(ticket, data: data, to: url)
            }
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    @discardableResult
    func write(
        _ config: WorkspaceConfigManager.WorkspaceConfig,
        to url: URL,
        workspaceID: String,
        ticket: WorkspaceAutoExportGate.Ticket
    ) async -> Bool {
        await write(config, to: url, workspaceID: workspaceID, publication: .prepared(ticket))
    }

    @discardableResult
    func write(_ config: WorkspaceConfigManager.WorkspaceConfig, to url: URL, workspaceID: String,
               ticket: WorkspaceAutoExportGate.ExplicitTicket) async -> Bool {
        await write(config, to: url, workspaceID: workspaceID, publication: .explicit(ticket))
    }

    private func write(_ config: WorkspaceConfigManager.WorkspaceConfig, to url: URL, workspaceID: String,
                       publication: Publication) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let beforeWrite { await beforeWrite() }
        // Projection may have observed a concurrent store commit before the
        // source context posts didSave. Its main-actor save must finish before
        // this snapshot is accepted. Encoding and filesystem I/O remain here.
        let current = await MainActor.run { publication.isCurrent }
        guard !Task.isCancelled, current else { return false }
        do {
            let data = try WorkspacePersistenceWork.measure("mirror_encode", workspaceID: workspaceID) {
                try encoder.encode(config)
            }
            guard !Task.isCancelled else { return false }
            let ticket = try WorkspacePersistenceWork.measure("mirror_write", workspaceID: workspaceID) {
                try publication.publish(data, to: url)
            }
            if let ticket {
                await WorkspacePersistenceCoordinator.autoExportDidWrite(ticket)
            } else {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "auto_export_skipped",
                    "reason": "superseded_or_deleted",
                    "workspace_id": workspaceID
                ], level: .debug)
            }
            return ticket != nil
        } catch {
            let nsError = error as NSError
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_failed",
                "diagnostic_result": "writeFailed",
                "workspace_id": workspaceID,
                "config_file": url.lastPathComponent,
                "path": url.path,
                "error_type": String(describing: type(of: error)),
                "error_domain": nsError.domain,
                "error_code": String(nsError.code),
                "error_description": nsError.localizedDescription
            ], level: .error)
            return false
        }
    }
}
