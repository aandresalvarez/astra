import Foundation
import SwiftData
import ASTRAModels

/// A cached SwiftData graph is not authority to replace a newer saved plugin
/// owner. Check its complete capability contract before preparing credentials
/// or mutating it. This is a read-only admission check, not another state owner.
@MainActor
enum PluginActivationAdmission {
    static func requireCurrent(in workspace: Workspace, modelContext: ModelContext) throws {
        guard workspace.modelContext === modelContext, !workspace.isDeleted else {
            throw PluginOperations.OperationError.workspaceChanged
        }
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        let id = workspace.id
        var query = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let rows = try saved.fetch(query)
        if rows.isEmpty {
            // Onboarding may Add to its newly inserted workspace. It has no
            // previously published owner or credential generation to replace.
            guard modelContext.insertedModelsArray.contains(where: { ($0 as? Workspace) === workspace }) else {
                throw PluginOperations.OperationError.workspaceChanged
            }
            return
        }
        guard rows.count == 1, let stored = rows.first else {
            throw PluginOperations.OperationError.workspaceChanged
        }
        let expected = WorkspaceCapabilityActivation.snapshot(workspace)
        let actual = WorkspaceCapabilityActivation.snapshot(stored)
        // Workspace timestamps describe unrelated work too. The activation
        // records include their own revisions, timestamps and sorted bindings.
        guard expected.state == actual.state, expected.activations == actual.activations,
              expected.retired == actual.retired, expected.pendingLegacy == actual.pendingLegacy else {
            throw PluginOperations.OperationError.workspaceChanged
        }
    }
}
