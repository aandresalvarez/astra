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
    private let destinations: [UUID: WorkspaceCleanupMirrorDestination]
    private let skipsExports: Bool

    private init(scope: [UUID: String], generation: WorkspaceCleanupStoreGeneration,
                 captured: WorkspaceSavedExportSnapshot.CapturedStore?,
                 tickets: [UUID: WorkspaceAutoExportGate.ExplicitTicket],
                 destinations: [UUID: WorkspaceCleanupMirrorDestination], skipsExports: Bool) {
        self.scope = scope
        self.generation = generation
        self.captured = captured
        self.tickets = tickets
        self.destinations = destinations
        self.skipsExports = skipsExports
    }

    @MainActor
    public static func prepare(modelContext: ModelContext) async -> WorkspaceCleanupMirrorBatch? {
        do {
            let source = WorkspaceSavedExportSource(modelContext.container)
            guard source.resolve() != nil else { return nil }
            let skipsExports = WorkspacePersistenceCoordinator.shouldSkipAutoExport()
            // Admission saves durable evidence from the current own files.
            // Finish every such save before fencing or copying the store;
            // otherwise the pass invalidates itself or projects older proof.
            let admitted = try WorkspacePersistenceWork.measure("cleanup_mirror_evidence_admission", workspaceID: "none") {
                try admitPriorMirrors(container: modelContext.container, skipsExports: skipsExports)
            }
            guard source.resolve() != nil, admitted.destinations.values.allSatisfy(\.isCurrent) else { return nil }
            // Register generation BEFORE fetching the final committed scope.
            // A different context can commit during admission or capture.
            let generation = try WorkspaceCleanupStoreGeneration(source: source)
            guard generation.isCurrent else { return nil }
            let scope = try WorkspacePersistenceWork.measure("cleanup_mirror_workspaces", workspaceID: "none") {
                try autoreleasepool {
                    let saved = ModelContext(modelContext.container)
                    saved.autosaveEnabled = false
                    let workspaces = try saved.fetch(FetchDescriptor<Workspace>())
                    guard workspaces.allSatisfy({ skipsExports || $0.primaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !PluginCredentialEvidenceUpgrade.requiresAdmission(workspace: $0) }) else {
                        throw PreparationError.unadmittedGeneration
                    }
                    return Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.primaryPath) })
                }
            }
            guard scope == admitted.scope, generation.isCurrent else { return nil }
            let destinations = admitted.destinations
            var tickets: [UUID: WorkspaceAutoExportGate.ExplicitTicket] = [:]
            for id in destinations.keys {
                // Never create a new ticket late for an already-old copy.
                tickets[id] = WorkspaceAutoExportGate.shared.reserveExport(for: id.uuidString)
            }
            let needsCopy = !tickets.isEmpty
                && !modelContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly)
            let captured = needsCopy ? try await WorkspaceSavedAutoExport.shared.captureCleanupStore(
                container: modelContext.container, workspaceID: tickets.keys.first?.uuidString ?? "none") : nil
            guard !Task.isCancelled, generation.isCurrent,
                  destinations.values.allSatisfy(\.isCurrent) else { return nil }
            return WorkspaceCleanupMirrorBatch(scope: scope, generation: generation, captured: captured,
                tickets: tickets, destinations: destinations, skipsExports: skipsExports)
        } catch {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_failed", "operation": "cleanup_mirror_snapshot",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    private enum PreparationError: Error { case unavailableDestination, unadmittedGeneration }

    @MainActor
    private static func admitPriorMirrors(container: ModelContainer, skipsExports: Bool) throws
        -> (scope: [UUID: String], destinations: [UUID: WorkspaceCleanupMirrorDestination]) {
        try autoreleasepool {
            // Never save unrelated pending edits in the caller's context.
            let saved = ModelContext(container)
            saved.autosaveEnabled = false
            let workspaces = try saved.fetch(FetchDescriptor<Workspace>())
            let scope = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.primaryPath) })
            var destinations: [UUID: WorkspaceCleanupMirrorDestination] = [:]
            for workspace in workspaces where !skipsExports && !workspace.primaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Task.checkCancellation()
                let destination = try WorkspaceCleanupMirrorDestination(workspacePath: workspace.primaryPath)
                guard WorkspaceMirrorRegistry(for: saved)?.register([destination.registeredWorkspacePath]) ?? true,
                      destination.isCurrent else { throw PreparationError.unavailableDestination }
                destinations[workspace.id] = destination
                try PluginCredentialEvidenceUpgrade.admit(workspace: workspace, context: saved)
                guard destination.isCurrent else { throw PreparationError.unavailableDestination }
            }
            return (scope, destinations)
        }
    }

    private var sourceIsCurrent: Bool { !Task.isCancelled && generation.isCurrent }

    // Validate the whole folder scope at the final cleanup boundary. Writes
    // check their own binding, so a stable N-workspace pass does O(N) checks.
    public var isCurrent: Bool { sourceIsCurrent && destinations.values.allSatisfy(\.isCurrent) }

    @MainActor
    public func write(workspaceID: UUID, modelContext: ModelContext) async -> Bool {
        await write(workspaceID: workspaceID, modelContext: modelContext, writer: .shared)
    }

    @MainActor
    func write(workspaceID: UUID, modelContext: ModelContext, writer: WorkspaceAutoExportWriter) async -> Bool {
        guard sourceIsCurrent, let path = scope[workspaceID] else { return false }
        if skipsExports
            || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let ticket = tickets[workspaceID], WorkspaceAutoExportGate.shared.isCurrent(ticket),
              let destination = destinations[workspaceID], destination.isCurrent else { return false }
        let prepared: WorkspaceSavedAutoExport.Prepared?
        if let captured {
            prepared = await WorkspaceSavedAutoExport.shared.prepareCleanupWorkspace(captured: captured, workspaceID: workspaceID)
        } else {
            // Preserve in-memory behavior; no SQLite file exists to share.
            prepared = try? await WorkspaceSavedAutoExport.shared.prepare(container: modelContext.container, workspaceID: workspaceID)
        }
        guard let prepared, sourceIsCurrent, destination.isCurrent,
              prepared.config.primaryPath == path else { return false }
        return await writer.write(prepared.config, to: destination.url, workspaceID: workspaceID.uuidString,
            ticket: ticket, sourceGeneration: generation, destination: destination) && sourceIsCurrent && destination.isCurrent
    }
}
