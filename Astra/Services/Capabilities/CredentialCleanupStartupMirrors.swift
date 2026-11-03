import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// All cleanup callers hold their producer lease across this suspension. No
/// ModelContext crosses actors: the persistence reader owns its background
/// context; this context contains only saved workspace identities.
@MainActor
enum CredentialCleanupStartupMirrors {
    static func rewrite(
        modelContext: ModelContext,
        trigger: WorkspacePersistenceWork.CleanupTrigger = .unspecified,
        write: ((Workspace, ModelContext) async -> Bool)? = nil
    ) async -> ModelContext? {
        await WorkspacePersistenceWork.withCleanupPass(trigger: trigger) {
            guard !Task.isCancelled, WorkspacePersistenceWork.measure("cleanup_mirror_admission", workspaceID: "none", {
                WorkspaceRecoveryTrust.allowsCleanup && PluginOperationRecovery.permitsCredentialCleanup(modelContext: modelContext)
            }) else { return nil }
            guard let batch = await WorkspaceCleanupMirrorBatch.prepare(modelContext: modelContext) else { return nil }
            let saved = ModelContext(modelContext.container)
            saved.autosaveEnabled = false
            let scope = batch.scope
            for id in scope.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard !Task.isCancelled else { return nil }
                WorkspacePersistenceWork.mirrorAttempt(workspaceID: id)
                let written: Bool
                if let write {
                    guard batch.isCurrent else { return nil }
                    guard let workspace = try? saved.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first
                    else { return nil }
                    written = await write(workspace, saved)
                } else { written = await batch.write(workspaceID: id, modelContext: saved) }
                WorkspacePersistenceWork.mirrorFinished(succeeded: written)
                guard written else { return nil }
            }
            // Workspaces may be added, removed or moved while projection awaits.
            // A successful old write does not vouch for that new mirror scope.
            let current = ModelContext(modelContext.container)
            current.autosaveEnabled = false
            guard batch.isCurrent, WorkspacePersistenceWork.measure("cleanup_mirror_scope_check", workspaceID: "none", {
                guard WorkspaceRecoveryTrust.allowsCleanup,
                      PluginOperationRecovery.permitsCredentialCleanup(modelContext: current),
                      let now = try? current.fetch(FetchDescriptor<Workspace>()) else { return false }
                return Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0.primaryPath) }) == scope && batch.isCurrent
            }) else { return nil }
            return current
        }
    }
}
