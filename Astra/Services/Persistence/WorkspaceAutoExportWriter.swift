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
    }

    private let lock = NSLock()
    private var generations: [String: Int] = [:]

    public func ticket(for workspaceID: String) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        return Ticket(workspaceID: workspaceID, generation: generations[workspaceID, default: 0])
    }

    /// A newer requested projection supersedes earlier reads as well as writes.
    /// Issued by the saving actor, before handing work to a background actor.
    public func beginExport(for workspaceID: String) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        generations[workspaceID, default: 0] += 1
        return Ticket(workspaceID: workspaceID, generation: generations[workspaceID, default: 0])
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[ticket.workspaceID, default: 0] == ticket.generation
    }

    /// A source-context save invalidates only the read that observed that
    /// context's previous save boundary, never a newer explicit snapshot.
    func invalidateIfCurrent(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        guard generations[ticket.workspaceID, default: 0] == ticket.generation else { return }
        generations[ticket.workspaceID, default: 0] += 1
    }

    /// Writes `data` to `url` only while no `retire` came after `ticket`.
    /// The slow part, writing the bytes, happens outside the gate, into a
    /// temporary file beside `url`; the gate is held only to check the
    /// generation and rename that file into place, so a `retire` on the main
    /// actor never waits on a stalled volume, and no write lands after it.
    /// False when the write was dropped.
    func writeIfCurrent(_ ticket: Ticket, data: Data, to url: URL) throws -> Bool {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).astra-export-\(UUID().uuidString)")
        try data.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        lock.lock()
        defer { lock.unlock() }
        guard generations[ticket.workspaceID, default: 0] == ticket.generation else { return false }
        guard Darwin.rename(staging.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }

    /// Drops every mirror write queued for `workspaceID` so far. Call it
    /// before removing a deleted workspace's mirror.
    public func retire(workspaceID: String) {
        lock.lock()
        defer { lock.unlock() }
        generations[workspaceID, default: 0] += 1
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
    ) -> Bool {
        guard !Task.isCancelled, WorkspaceAutoExportGate.shared.isCurrent(ticket) else { return false }
        do {
            let data = try WorkspacePersistenceWork.measure("mirror_encode", workspaceID: workspaceID) {
                try encoder.encode(config)
            }
            guard !Task.isCancelled else { return false }
            let written = try WorkspacePersistenceWork.measure("mirror_write", workspaceID: workspaceID) {
                try WorkspaceAutoExportGate.shared.writeIfCurrent(ticket, data: data, to: url)
            }
            if !written {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "auto_export_skipped",
                    "reason": "superseded_or_deleted",
                    "workspace_id": workspaceID
                ], level: .debug)
            }
            return written
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
