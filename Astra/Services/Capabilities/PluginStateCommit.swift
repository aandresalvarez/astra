import Foundation
import SwiftData
import ASTRAModels

/// Saves workspace/account state together with its recovery scope. File-library
/// transactions use a separate prepared manifest; ordinary edits need only the
/// receipt in the same SwiftData save, followed by an idempotent mirror pass.
@MainActor
enum PluginStateCommit {
    enum Outcome {
        case completed(UUID)
        case pendingRecovery(UUID)
        case notCommitted(Error)
        case indeterminate(UUID, Error)
    }

    static func save(
        workspace: Workspace?, accounts: [Connector] = [], pluginIDs: [String] = [],
        kind: PluginOperationReceipt.Kind = .configure, modelContext: ModelContext,
        persist: (ModelContext) throws -> Void,
        export: ((Workspace) -> Bool)? = nil, publishesCompleted: Bool = true
    ) -> Outcome {
        let affected: [Workspace]
        do { affected = try PluginStateMirrors.affectedWorkspaces(workspace: workspace, accounts: accounts, modelContext: modelContext) }
        catch { return .notCommitted(error) }
        return save(workspaceIDs: affected.map(\.id), pluginIDs: pluginIDs, kind: kind,
            modelContext: modelContext, persist: persist, export: export, publishesCompleted: publishesCompleted)
    }

    /// Callers reconciling multiple activations resolve the complete scope
    /// before saving. Failure to discover that scope must abort the change.
    static func save(
        workspaceIDs: [UUID], pluginIDs: [String], kind: PluginOperationReceipt.Kind,
        modelContext: ModelContext, persist: (ModelContext) throws -> Void,
        export: ((Workspace) -> Bool)? = nil, publishesCompleted: Bool = true
    ) -> Outcome {
        let outcome = PluginOperationCommit.save(kind: kind, pluginIDs: pluginIDs, workspaceIDs: Array(Set(workspaceIDs)),
            modelContext: modelContext, persist: persist)
        switch outcome {
        case .notCommitted(let error): return .notCommitted(error)
        case .indeterminate(let id, let error): return .indeterminate(id, error)
        case .committed(let receipt, let reportedFailure):
            guard !reportedFailure else {
                publish(receipt)
                return .pendingRecovery(receipt.id)
            }
            let rewritten: ((Workspace, ModelContext) -> Bool)? = export.map { write in { workspace, _ in write(workspace) } }
            let result = PluginOperationRecovery.resumePending(modelContext: modelContext, only: receipt.id, export: rewritten)
            let completed = result.completed == 1
            if publishesCompleted || !completed { publish(receipt) }
            return completed ? .completed(receipt.id) : .pendingRecovery(receipt.id)
        }
    }

    private static func publish(_ receipt: PluginOperationCommit.Snapshot) {
        if receipt.workspaceIDs.isEmpty { CapabilityCatalogPersistenceEvents.post(.global) }
        else { for id in receipt.workspaceIDs { CapabilityCatalogPersistenceEvents.post(.workspace(id)) } }
    }

}
