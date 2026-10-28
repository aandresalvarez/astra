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
        write: (Workspace, ModelContext) async -> Bool = {
            await WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: $0, modelContext: $1)
        }
    ) async -> ModelContext? {
        guard !Task.isCancelled, WorkspaceRecoveryTrust.allowsCleanup,
              PluginOperationRecovery.permitsCredentialCleanup(modelContext: modelContext) else { return nil }
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        guard let workspaces = try? saved.fetch(FetchDescriptor<Workspace>()) else { return nil }
        let scope = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.primaryPath) })
        for workspace in workspaces {
            guard !Task.isCancelled, await write(workspace, saved) else { return nil }
        }
        // Workspaces may be added, removed or moved while projection awaits.
        // A successful old write does not vouch for that new mirror scope.
        let current = ModelContext(modelContext.container)
        current.autosaveEnabled = false
        guard !Task.isCancelled, WorkspaceRecoveryTrust.allowsCleanup,
              PluginOperationRecovery.permitsCredentialCleanup(modelContext: current),
              let now = try? current.fetch(FetchDescriptor<Workspace>()),
              Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0.primaryPath) }) == scope else { return nil }
        return current
    }
}
