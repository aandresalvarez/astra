import Foundation

/// The single owner of a workspace's capability enablement state.
///
/// Seven stored arrays on `Workspace` record which capability packages, packs
/// and shared (global) skills, connectors and tools a workspace has turned on,
/// plus the plugin versions it installed. They used to be written from more
/// than twenty places, views included. Every write now goes through
/// `mutate`/`apply`/`restore` here, and `CapabilityActivationOwnerFitnessTests`
/// fails on a direct write anywhere else, so moving this state into its own
/// model later is a change to `state(of:)` and `apply(_:to:)` alone.
///
/// Nothing here saves, posts notifications or bumps `updatedAt` on its own:
/// callers keep their existing persistence and timestamp handling, so routing a
/// writer through the owner does not change when or how it commits.
public enum WorkspaceCapabilityActivation {
    /// Reads the enablement state exactly as stored.
    public static func state(of workspace: Workspace) -> WorkspaceCapabilityActivationState {
        WorkspaceCapabilityActivationState(
            capabilityIDs: workspace.enabledCapabilityIDs,
            packIDs: workspace.enabledPackIDs,
            globalSkillIDs: workspace.enabledGlobalSkillIDs,
            globalConnectorIDs: workspace.enabledGlobalConnectorIDs,
            globalToolIDs: workspace.enabledGlobalToolIDs,
            pluginIDs: workspace.installedPluginIDs,
            pluginVersions: workspace.installedPluginVersions
        )
    }

    /// Writes `state` back, touching only the arrays that changed. Assigning
    /// an equal value to a SwiftData property still notifies its observers,
    /// and every writer used to touch only the arrays it changed.
    public static func apply(_ state: WorkspaceCapabilityActivationState, to workspace: Workspace) {
        if workspace.enabledCapabilityIDs != state.capabilityIDs {
            workspace.enabledCapabilityIDs = state.capabilityIDs
        }
        if workspace.enabledPackIDs != state.packIDs {
            workspace.enabledPackIDs = state.packIDs
        }
        if workspace.enabledGlobalSkillIDs != state.globalSkillIDs {
            workspace.enabledGlobalSkillIDs = state.globalSkillIDs
        }
        if workspace.enabledGlobalConnectorIDs != state.globalConnectorIDs {
            workspace.enabledGlobalConnectorIDs = state.globalConnectorIDs
        }
        if workspace.enabledGlobalToolIDs != state.globalToolIDs {
            workspace.enabledGlobalToolIDs = state.globalToolIDs
        }
        if workspace.installedPluginIDs != state.pluginIDs {
            workspace.installedPluginIDs = state.pluginIDs
        }
        if workspace.installedPluginVersions != state.pluginVersions {
            workspace.installedPluginVersions = state.pluginVersions
        }
    }

    /// Reads, changes and writes back the enablement state in one step.
    @discardableResult
    public static func mutate<Result>(
        _ workspace: Workspace,
        _ body: (inout WorkspaceCapabilityActivationState) throws -> Result
    ) rethrows -> Result {
        var state = state(of: workspace)
        let result = try body(&state)
        apply(state, to: workspace)
        return result
    }

    /// The enablement state plus `updatedAt`, for undoing in-memory changes
    /// after a failed save. `ModelContext` rollback reverts inserts and deletes
    /// but not mutations to a persisted model's stored arrays, so lifecycle
    /// services restore these by hand.
    public struct Snapshot: Equatable, Sendable {
        public let state: WorkspaceCapabilityActivationState
        public let updatedAt: Date
    }

    public static func snapshot(_ workspace: Workspace) -> Snapshot {
        Snapshot(state: state(of: workspace), updatedAt: workspace.updatedAt)
    }

    public static func restore(_ snapshot: Snapshot, to workspace: Workspace) {
        apply(snapshot.state, to: workspace)
        workspace.updatedAt = snapshot.updatedAt
    }
}

/// A workspace's capability enablement state as a plain value. The arrays keep
/// their stored order and content, including a `pluginVersions` array that has
/// fallen out of step with `pluginIDs`, so copying state between workspaces
/// stays exact.
public struct WorkspaceCapabilityActivationState: Equatable, Sendable {
    /// Enabled capability package IDs.
    public var capabilityIDs: [String]
    /// Enabled pack IDs.
    public var packIDs: [String]
    /// Shared skills, connectors and tools turned on for this workspace, by
    /// row UUID string.
    public var globalSkillIDs: [String]
    public var globalConnectorIDs: [String]
    public var globalToolIDs: [String]
    /// Installed plugin IDs and their versions, paired by index.
    public var pluginIDs: [String]
    public var pluginVersions: [String]

    public init(
        capabilityIDs: [String] = [],
        packIDs: [String] = [],
        globalSkillIDs: [String] = [],
        globalConnectorIDs: [String] = [],
        globalToolIDs: [String] = [],
        pluginIDs: [String] = [],
        pluginVersions: [String] = []
    ) {
        self.capabilityIDs = capabilityIDs
        self.packIDs = packIDs
        self.globalSkillIDs = globalSkillIDs
        self.globalConnectorIDs = globalConnectorIDs
        self.globalToolIDs = globalToolIDs
        self.pluginIDs = pluginIDs
        self.pluginVersions = pluginVersions
    }

    public mutating func enableCapability(_ id: String) {
        Self.appendUnique(id, to: &capabilityIDs)
    }

    public mutating func enableGlobalSkill(_ id: String) {
        Self.appendUnique(id, to: &globalSkillIDs)
    }

    public mutating func enableGlobalConnector(_ id: String) {
        Self.appendUnique(id, to: &globalConnectorIDs)
    }

    public mutating func enableGlobalTool(_ id: String) {
        Self.appendUnique(id, to: &globalToolIDs)
    }

    /// Turns a shared skill off when it is on and on when it is off.
    public mutating func toggleGlobalSkill(_ id: String) {
        if let index = globalSkillIDs.firstIndex(of: id) {
            globalSkillIDs.remove(at: index)
        } else {
            globalSkillIDs.append(id)
        }
    }

    /// Records `version` for `id`, appending it when it is not installed yet.
    /// A versions array that has fallen behind the IDs is padded rather than
    /// the write being dropped, which would freeze the recorded version.
    public mutating func recordInstalledPlugin(id: String, version: String) {
        if let index = pluginIDs.firstIndex(of: id) {
            while pluginVersions.count <= index {
                pluginVersions.append("")
            }
            pluginVersions[index] = version
        } else {
            pluginIDs.append(id)
            pluginVersions.append(version)
        }
    }

    /// Removes every record of `id`, keeping the versions paired with the IDs
    /// that remain even when the versions array is shorter than the IDs.
    public mutating func removeInstalledPlugin(id: String) {
        while let index = pluginIDs.firstIndex(of: id) {
            pluginIDs.remove(at: index)
            if index < pluginVersions.count {
                pluginVersions.remove(at: index)
            }
        }
    }

    private static func appendUnique(_ id: String, to ids: inout [String]) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }
}
