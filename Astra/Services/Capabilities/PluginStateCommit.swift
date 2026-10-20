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
        export: ((Workspace) -> Bool)? = nil
    ) -> Outcome {
        let affected: [Workspace]
        do { affected = try PluginStateMirrors.affectedWorkspaces(workspace: workspace, accounts: accounts, modelContext: modelContext) }
        catch { return .notCommitted(error) }
        let outcome = PluginOperationCommit.save(kind: kind, pluginIDs: pluginIDs, workspaceIDs: affected.map(\.id),
            modelContext: modelContext, persist: persist)
        switch outcome {
        case .notCommitted(let error): return .notCommitted(error)
        case .indeterminate(let id, let error): return .indeterminate(id, error)
        case .committed(let receipt, let reportedFailure):
            guard !reportedFailure else { return .pendingRecovery(receipt.id) }
            let rewritten: ((Workspace, ModelContext) -> Bool)? = export.map { write in { workspace, _ in write(workspace) } }
            let result = PluginOperationRecovery.resumePending(modelContext: modelContext, only: receipt.id, export: rewritten)
            return result.completed == 1 ? .completed(receipt.id) : .pendingRecovery(receipt.id)
        }
    }
}
