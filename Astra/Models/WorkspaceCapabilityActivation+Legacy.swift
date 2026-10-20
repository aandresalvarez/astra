import Foundation
import SwiftData

/// Compatibility and frozen launch views of existing pending legacy fields.
/// The same activation owner controls every read, mutation and rollback.
extension WorkspaceCapabilityActivation {
    /// Turn off pending V19 enablement without guessing which resource rows
    /// a package owns. Keep its installation marker for migration and scope;
    /// another plugin's legacy metadata is left byte-for-byte in place.
    @discardableResult
    public static func turnOffPendingLegacyPlugin(_ pluginID: String, in workspace: Workspace) -> Bool {
        guard activation(for: pluginID, in: workspace) == nil,
              workspace.legacyEnabledCapabilityIDs.contains(pluginID) else { return false }
        if !workspace.legacyInstalledPluginIDs.contains(pluginID) {
            let index = workspace.legacyInstalledPluginIDs.count
            while workspace.legacyInstalledPluginVersions.count < index { workspace.legacyInstalledPluginVersions.append("") }
            workspace.legacyInstalledPluginVersions.insert("", at: index)
            workspace.legacyInstalledPluginIDs.append(pluginID)
        }
        workspace.legacyEnabledCapabilityIDs.removeAll { $0 == pluginID }
        return true
    }

    public static func isPluginOriginDisabled(_ pluginID: String?, in workspace: Workspace) -> Bool {
        guard let id = pluginID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return false }
        if let activation = activation(for: id, in: workspace) { return !activation.isEnabled || activation.awaitingUpdate }
        return workspace.legacyInstalledPluginIDs.contains(id) && !workspace.legacyEnabledCapabilityIDs.contains(id)
    }

    /// Immutable request-time view of the still-pending legacy state. It is
    /// derived from Workspace's existing fields, never a second mutable owner.
    public struct PendingLegacyState: Codable, Equatable, Sendable {
        public let enabledPluginIDs: [String]
        public let installedPluginIDs: [String]
        public let installedPluginVersions: [String]
    }

    public static func pendingLegacyState(of workspace: Workspace) -> PendingLegacyState {
        PendingLegacyState(enabledPluginIDs: workspace.legacyEnabledCapabilityIDs,
            installedPluginIDs: workspace.legacyInstalledPluginIDs,
            installedPluginVersions: workspace.legacyInstalledPluginVersions)
    }

    /// Known pending installations, with their original paired version when
    /// present. Consumers never reconstruct ownership from parallel arrays.
    public static func pendingLegacyInstallations(in workspace: Workspace) -> [(id: String, version: String)] {
        var seen = Set<String>()
        var result: [(id: String, version: String)] = []
        for (index, id) in workspace.legacyInstalledPluginIDs.enumerated() where seen.insert(id).inserted {
            result.append((id, index < workspace.legacyInstalledPluginVersions.count ? workspace.legacyInstalledPluginVersions[index] : ""))
        }
        for id in workspace.legacyEnabledCapabilityIDs where seen.insert(id).inserted { result.append((id, "")) }
        return result
    }

    public static func hasPendingLegacyEnablement(_ pluginID: String?, in workspace: Workspace) -> Bool {
        guard let id = pluginID, !id.isEmpty, activation(for: id, in: workspace) == nil else { return false }
        return workspace.legacyEnabledCapabilityIDs.contains(id)
    }

    public enum SharedResourceKind { case skill, connector, tool }

    public static func hasSharedResource(_ kind: SharedResourceKind, id: UUID, in workspace: Workspace) -> Bool {
        switch kind {
        case .skill: workspace.enabledGlobalSkillIDs.contains(id.uuidString)
        case .connector: workspace.enabledGlobalConnectorIDs.contains(id.uuidString)
        case .tool: workspace.enabledGlobalToolIDs.contains(id.uuidString)
        }
    }

    public static func permitsPendingLegacyResource(_ pluginID: String?, id: UUID, shared: Bool,
                                                   kind: SharedResourceKind, in workspace: Workspace) -> Bool {
        !isPluginOriginDisabled(pluginID, in: workspace) || (shared && hasSharedResource(kind, id: id, in: workspace))
    }

    /// Launch copies alone consume a frozen legacy view. Durable edits go
    /// through the explicit membership operations and their save boundary.
    public static func applyFrozenPendingLegacy(_ state: PendingLegacyState?, to target: Workspace) {
        guard target.modelContext == nil, let state else { return }
        restorePendingLegacy(state, to: target)
    }

    public static func copyPendingLegacyEnablement(from source: Workspace, to target: Workspace) {
        applyFrozenPendingLegacy(pendingLegacyState(of: source), to: target)
    }

    static func restorePendingLegacy(_ state: PendingLegacyState, to workspace: Workspace) {
        workspace.legacyEnabledCapabilityIDs = state.enabledPluginIDs
        workspace.legacyInstalledPluginIDs = state.installedPluginIDs
        workspace.legacyInstalledPluginVersions = state.installedPluginVersions
    }

}
