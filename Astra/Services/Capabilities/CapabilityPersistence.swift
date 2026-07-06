import Foundation
import SwiftData
import ASTRAModels

/// The save seam used by capability lifecycle services (install, enable,
/// disable, uninstall). Production goes through
/// `WorkspacePersistenceCoordinator.saveAndAutoExport`; tests inject a stub
/// that returns `false` to exercise the save-failure rollback paths without
/// a real failing `ModelContext`.
enum CapabilityPersistence {
    /// The property is nonisolated so it can be a default argument on the
    /// `@MainActor` lifecycle methods; the closure it holds is `@MainActor`
    /// and only runs the coordinator save when actually invoked.
    static let defaultPersist: @MainActor (Workspace?, ModelContext) -> Bool = { workspace, context in
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context)
    }
}

/// Snapshot of a workspace's capability-membership arrays. `ModelContext`
/// rollback reverts pending object inserts/deletes, but NOT in-memory
/// mutations to a persisted model's stored arrays — so enable/disable must
/// restore these by hand on a save failure or the workspace is left listing
/// resources that were never committed (or hiding ones never removed).
struct WorkspaceCapabilityMembershipSnapshot {
    private let enabledGlobalSkillIDs: [String]
    private let enabledGlobalConnectorIDs: [String]
    private let enabledGlobalToolIDs: [String]
    private let enabledCapabilityIDs: [String]
    private let installedPluginIDs: [String]
    private let installedPluginVersions: [String]
    private let updatedAt: Date

    init(_ workspace: Workspace) {
        enabledGlobalSkillIDs = workspace.enabledGlobalSkillIDs
        enabledGlobalConnectorIDs = workspace.enabledGlobalConnectorIDs
        enabledGlobalToolIDs = workspace.enabledGlobalToolIDs
        enabledCapabilityIDs = workspace.enabledCapabilityIDs
        installedPluginIDs = workspace.installedPluginIDs
        installedPluginVersions = workspace.installedPluginVersions
        updatedAt = workspace.updatedAt
    }

    func restore(to workspace: Workspace) {
        workspace.enabledGlobalSkillIDs = enabledGlobalSkillIDs
        workspace.enabledGlobalConnectorIDs = enabledGlobalConnectorIDs
        workspace.enabledGlobalToolIDs = enabledGlobalToolIDs
        workspace.enabledCapabilityIDs = enabledCapabilityIDs
        workspace.installedPluginIDs = installedPluginIDs
        workspace.installedPluginVersions = installedPluginVersions
        workspace.updatedAt = updatedAt
    }
}
