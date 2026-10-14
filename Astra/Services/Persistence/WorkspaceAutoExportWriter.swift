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

    func write(
        _ config: WorkspaceConfigManager.WorkspaceConfig,
        to url: URL,
        workspaceID: String,
        ticket: WorkspaceAutoExportGate.Ticket
    ) {
        do {
            let data = try encoder.encode(config)
            let written = try WorkspaceAutoExportGate.shared.writeIfCurrent(ticket, data: data, to: url)
            if !written {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "auto_export_skipped",
                    "reason": "workspace_deleted",
                    "workspace_id": workspaceID
                ], level: .debug)
            }
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
        }
    }
}
