import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// The one post-save mirror export for plugin state: an activation's
/// settings, a binding (Add account, Make default), an account's own fields
/// (its name, URL, service, sharing).
///
/// A recovery restores SwiftData from the workspace mirrors, so a saved
/// change a mirror never got would revert. After such a save, the mirror of
/// the workspace that made it and of every workspace carrying one of the
/// accounts it changed (`WorkspaceConfigManager.workspacesMirroring`: a
/// binding, a shared list, a skill) is written, now. Paths that also clean
/// secrets write theirs before the cleanup settles (`beforeSettling`).
@MainActor
enum PluginStateMirrors {
    /// Writes the mirrors a saved change to `workspace`'s plugin state and
    /// to `accounts` left stale. False when one couldn't be written.
    @discardableResult
    static func exportAfterSave(
        workspace: Workspace?,
        accounts: [Connector] = [],
        modelContext: ModelContext,
        export: ((Workspace) -> Bool)? = nil
    ) -> Bool {
        let stored = accounts.isEmpty ? [] : (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        let mirrored = (workspace.map { [$0] } ?? [])
            + WorkspaceConfigManager.workspacesMirroring(accountIDs: Set(accounts.map(\.id)), among: stored, modelContext: modelContext)
        guard let export else { return WorkspaceConfigManager.exportMirrorsNow(mirrored, modelContext: modelContext) }
        var seen = Set<UUID>()
        return mirrored.filter { seen.insert($0.id).inserted }.reduce(true) { export($1) && $0 }
    }
}
