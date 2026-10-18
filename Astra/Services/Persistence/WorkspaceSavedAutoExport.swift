import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A queued projection does not own the store. Resolve this weak reference only
/// when the reader actor starts work, so a busy export queue cannot prolong a
/// closed owner's main context and autosave timer. Swift weak access is atomic;
/// the resolved ModelContainer itself is Sendable.
final class WorkspaceSavedExportSource: @unchecked Sendable {
    private weak var container: ModelContainer?
    init(_ container: ModelContainer) { self.container = container }
    func resolve() -> ModelContainer? { container }

    /// A deferred owner can remain alive briefly after its store is replaced.
    /// Check the authority before touching any of its lazy managed models.
    static func isAvailable(_ container: ModelContainer, workspaceID: String) -> Bool {
        for configuration in container.configurations where !configuration.isStoredInMemoryOnly {
            do { _ = try FileManager.default.attributesOfItem(atPath: configuration.url.path) }
            catch {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "auto_export_skipped", "reason": "backing_store_unavailable",
                    "workspace_id": workspaceID, "error_type": String(describing: type(of: error))
                ], level: .debug)
                return false
            }
        }
        return true
    }
}

/// A serialized, read-only projection of an immutable saved-store snapshot.
/// No managed model or context crosses actors. The temporary SQLite copy is
/// discarded after projection; SwiftData remains the durable authority.
actor WorkspaceSavedAutoExport {
    static let shared = WorkspaceSavedAutoExport()
    private let beforeProjection: (@Sendable () async -> Void)?

    init(beforeProjection: (@Sendable () async -> Void)? = nil) { self.beforeProjection = beforeProjection }

    struct Prepared: Sendable {
        let config: WorkspaceConfigManager.WorkspaceConfig
        let ranOnMainThread: Bool
    }

    func export(source: WorkspaceSavedExportSource, workspaceID: UUID, url: URL,
                ticket: WorkspaceAutoExportGate.Ticket) async -> Bool {
        // End the strong container scope before waiting for the JSON writer.
        // A congested writer queue only needs the value snapshot, not a live
        // store or its main context's autosave timer.
        guard let prepared = await prepareForExport(source: source, workspaceID: workspaceID,
            url: url, ticket: ticket) else { return false }
        return await WorkspaceAutoExportWriter.shared.write(prepared.config, to: url,
            workspaceID: workspaceID.uuidString, ticket: ticket)
    }

    func prepare(container: ModelContainer, workspaceID: UUID) async throws -> Prepared? {
        if container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
            // Preview/test stores have no SQLite snapshot. Serialize their
            // read with the main-actor edits instead of racing lazy faults.
            return try await MainActor.run { try Self.prepareRows(container: container, workspaceID: workspaceID) }
        }
        return try WorkspaceSavedExportSnapshot.read(container: container, workspaceID: workspaceID.uuidString) {
            guard !Task.isCancelled else { return nil }
            return try Self.prepareRows(container: $0, workspaceID: workspaceID)
        }
    }

    /// A failed quit-time save must not mirror the source context's unsaved
    /// edits. Termination may synchronously read only its committed authority.
    @MainActor static func prepareForTermination(container: ModelContainer, workspaceID: UUID) throws -> Prepared? {
        if container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
            return try prepareRows(container: container, workspaceID: workspaceID)
        }
        return try WorkspaceSavedExportSnapshot.read(container: container, workspaceID: workspaceID.uuidString) {
            try prepareRows(container: $0, workspaceID: workspaceID)
        }
    }

    nonisolated private static func prepareRows(container: ModelContainer, workspaceID: UUID) throws -> Prepared? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == workspaceID })
        guard let workspace = try context.fetch(descriptor).first else { return nil }
        // No suspension while the context and its managed models are alive.
        return WorkspacePersistenceWork.measure("mirror_snapshot", workspaceID: workspaceID.uuidString) {
            guard let config = WorkspaceConfigManager.export(workspace: workspace, modelContext: context) else { return nil }
            return Prepared(config: config, ranOnMainThread: Thread.isMainThread)
        }
    }

    @discardableResult
    func export(container: ModelContainer, workspaceID: UUID, url: URL,
                ticket: WorkspaceAutoExportGate.Ticket) async -> Bool {
        await export(source: WorkspaceSavedExportSource(container), workspaceID: workspaceID, url: url, ticket: ticket)
    }

    func prepareForExport(source: WorkspaceSavedExportSource, workspaceID: UUID, url: URL,
                          ticket: WorkspaceAutoExportGate.Ticket) async -> Prepared? {
        await prepareForExport(source: source, workspaceID: workspaceID, url: url,
            isCurrent: { WorkspaceAutoExportGate.shared.isCurrent(ticket) })
    }

    func prepareForExport(source: WorkspaceSavedExportSource, workspaceID: UUID, url: URL,
                          readTicket: WorkspaceAutoExportGate.ReadTicket) async -> Prepared? {
        await prepareForExport(source: source, workspaceID: workspaceID, url: url,
            isCurrent: { WorkspaceAutoExportGate.shared.isCurrent(readTicket) })
    }

    func prepareForExport(source: WorkspaceSavedExportSource, workspaceID: UUID, url: URL,
                          lease: WorkspaceSavedExportLease) async -> Prepared? {
        await prepareForExport(source: source, workspaceID: workspaceID, url: url,
            isCurrent: { lease.isCurrent }, read: { container in
                if container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                    return try await MainActor.run {
                        guard lease.seal() else { return nil }
                        return try Self.prepareRows(container: container, workspaceID: workspaceID)
                    }
                }
                // Keep the expensive copy and traversal on this serialized
                // actor. Only sealing yields to the source context's actor.
                let captured = try WorkspaceSavedExportSnapshot.capture(container: container,
                    workspaceID: workspaceID.uuidString)
                guard await MainActor.run(body: { lease.seal() }) else { return nil }
                if let beforeProjection = self.beforeProjection { await beforeProjection() }
                guard !Task.isCancelled, lease.isCurrent else { return nil }
                return try captured.read { try Self.prepareRows(container: $0, workspaceID: workspaceID) }
            })
    }

    private func prepareForExport(source: WorkspaceSavedExportSource, workspaceID: UUID, url: URL,
                                  isCurrent: @Sendable () -> Bool,
                                  read: ((ModelContainer) async throws -> Prepared?)? = nil) async -> Prepared? {
        // Coalesce queued requests before paying to fault the workspace graph.
        guard !Task.isCancelled, isCurrent(),
              let container = source.resolve() else { return nil }
        // A caller may have closed and removed a temporary/replaced store
        // before this queued read starts. Do not fault models from that store.
        guard WorkspaceSavedExportSource.isAvailable(container, workspaceID: workspaceID.uuidString) else { return nil }
        do {
            let prepared: Prepared?
            if let read { prepared = try await read(container) }
            else { prepared = try await prepare(container: container, workspaceID: workspaceID) }
            guard let prepared, !Task.isCancelled,
                  isCurrent() else { return nil }
            // A path move saved by a caller that did not request a new mirror
            // must not write the new workspace config into the old folder.
            let savedURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: prepared.config.primaryPath))
            guard savedURL == url else { return nil }
            return prepared
        } catch {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_failed", "operation": "saved_mirror_snapshot",
                "workspace_id": workspaceID.uuidString, "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }
}
