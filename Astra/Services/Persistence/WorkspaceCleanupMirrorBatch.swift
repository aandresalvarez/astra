import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// One stable committed-store copy per credential cleanup pass. No snapshot
/// context or model survives an await; each workspace reader drains its own
/// autorelease pool before the next JSON export or removal of the copy.
public final class WorkspaceCleanupMirrorBatch {
    public let scope: [UUID: String]
    private let generation: WorkspaceCleanupStoreGeneration
    private let captured: WorkspaceSavedExportSnapshot.CapturedStore?
    private let tickets: [UUID: WorkspaceAutoExportGate.ExplicitTicket]

    private init(scope: [UUID: String], generation: WorkspaceCleanupStoreGeneration,
                 captured: WorkspaceSavedExportSnapshot.CapturedStore?,
                 tickets: [UUID: WorkspaceAutoExportGate.ExplicitTicket]) {
        self.scope = scope
        self.generation = generation
        self.captured = captured
        self.tickets = tickets
    }

    @MainActor
    public static func prepare(modelContext: ModelContext) async -> WorkspaceCleanupMirrorBatch? {
        do {
            // Register generation BEFORE even fetching scope. A different
            // context can commit while the background backup is in progress.
            let generation = try WorkspaceCleanupStoreGeneration(container: modelContext.container)
            let saved = ModelContext(modelContext.container)
            saved.autosaveEnabled = false
            let workspaces = try WorkspacePersistenceWork.measure("cleanup_mirror_workspaces", workspaceID: "none") {
                try saved.fetch(FetchDescriptor<Workspace>())
            }
            let scope = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.primaryPath) })
            var tickets: [UUID: WorkspaceAutoExportGate.ExplicitTicket] = [:]
            for (id, path) in scope where !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard WorkspaceMirrorRegistry(for: saved)?.register([path]) ?? true else { return nil }
                // Never create a new ticket late for an already-old copy.
                tickets[id] = WorkspaceAutoExportGate.shared.reserveExport(for: id.uuidString)
            }
            let needsCopy = !tickets.isEmpty && !WorkspacePersistenceCoordinator.shouldSkipAutoExport()
                && !modelContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly)
            let captured = needsCopy ? try await WorkspaceSavedAutoExport.shared.captureCleanupStore(
                container: modelContext.container, workspaceID: tickets.keys.first?.uuidString ?? "none") : nil
            guard !Task.isCancelled, generation.isCurrent else { return nil }
            return WorkspaceCleanupMirrorBatch(scope: scope, generation: generation, captured: captured, tickets: tickets)
        } catch {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_failed", "operation": "cleanup_mirror_snapshot",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    public var isCurrent: Bool { !Task.isCancelled && generation.isCurrent }

    @MainActor
    public func write(workspaceID: UUID, modelContext: ModelContext) async -> Bool {
        await write(workspaceID: workspaceID, modelContext: modelContext, writer: .shared)
    }

    @MainActor
    func write(workspaceID: UUID, modelContext: ModelContext, writer: WorkspaceAutoExportWriter) async -> Bool {
        guard isCurrent, let path = scope[workspaceID] else { return false }
        if WorkspacePersistenceCoordinator.shouldSkipAutoExport()
            || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let ticket = tickets[workspaceID], WorkspaceAutoExportGate.shared.isCurrent(ticket),
              let url = WorkspaceConfigManager.autoExportTarget(for: path).url else { return false }
        guard let captured else {
            // Preserve in-memory behavior; no SQLite file exists to share.
            let id = workspaceID
            guard let workspace = try? modelContext.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first
            else { return false }
            return await WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: workspace, modelContext: modelContext)
                && isCurrent
        }
        guard let prepared = await WorkspaceSavedAutoExport.shared.prepareCleanupWorkspace(
            captured: captured, workspaceID: workspaceID), isCurrent,
              prepared.config.primaryPath == path else { return false }
        return await writer.write(prepared.config, to: url, workspaceID: workspaceID.uuidString,
            ticket: ticket, sourceGeneration: generation) && isCurrent
    }
}
