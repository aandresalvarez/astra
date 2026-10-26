import Foundation
import SwiftData
import ASTRAModels

extension WorkspacePersistenceCoordinator {
    /// Saves once, then refreshes the mirror of every workspace a store-wide
    /// change touched (an Update reconciled across workspaces, an account
    /// deleted everywhere), so recovery never restores what was just undone.
    public static func saveAndAutoExportOrThrow(
        workspaces: [Workspace],
        modelContext: ModelContext
    ) throws {
        try saveAndAutoExportOrThrow(workspace: nil, modelContext: modelContext)
        guard !shouldSkipAutoExport() else { return }
        var seen = Set<UUID>()
        for workspace in workspaces where !workspace.isDeleted && seen.insert(workspace.id).inserted {
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }
    }
}
