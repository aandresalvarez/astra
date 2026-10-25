import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Resolves the mirror scope of workspace/account changes. New mutations
/// use that scope before saving through `PluginStateCommit`; legacy resource
/// editors still call `exportAfterSave` until their save boundary is migrated.
/// Shared accounts include every workspace carrying them through a binding,
/// a shared list or a skill, rather than only the clicked workspace.
@MainActor
enum PluginStateMirrors {
    static func affectedWorkspaces(
        workspace: Workspace?, accounts: [Connector] = [], modelContext: ModelContext,
        fetchWorkspaces: (() throws -> [Workspace])? = nil
    ) throws -> [Workspace] {
        let stored = accounts.isEmpty ? [] : try (fetchWorkspaces ?? { try modelContext.fetch(FetchDescriptor<Workspace>()) })()
        let mirroring = try WorkspaceConfigManager.workspacesMirroring(
            accountIDs: Set(accounts.map(\.id)), among: stored, modelContext: modelContext)
        var seen = Set<UUID>()
        return ((workspace.map { [$0] } ?? []) + mirroring).filter { seen.insert($0.id).inserted }
    }

    /// Writes the mirrors a saved change to `workspace`'s plugin state and
    /// to `accounts` left stale. False when one couldn't be written.
    @discardableResult
    static func exportAfterSave(
        workspace: Workspace?,
        accounts: [Connector] = [],
        modelContext: ModelContext,
        export: ((Workspace) -> Bool)? = nil,
        fetchWorkspaces: (() throws -> [Workspace])? = nil
    ) -> Bool {
        guard let mirrored = try? affectedWorkspaces(workspace: workspace, accounts: accounts,
            modelContext: modelContext, fetchWorkspaces: fetchWorkspaces) else { return false }
        guard let export else { return WorkspaceConfigManager.exportMirrorsNow(mirrored, modelContext: modelContext) }
        var seen = Set<UUID>()
        return mirrored.filter { seen.insert($0.id).inserted }.reduce(true) { export($1) && $0 }
    }
}
