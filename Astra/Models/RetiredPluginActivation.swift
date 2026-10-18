import Foundation
import SwiftData

/// What Remove keeps of a workspace's plugin activation, so nothing the
/// person made is lost or left acting for a plugin that is gone.
///
/// - The namespace seed (a chosen-file import gives each activation its own):
///   templates and schedules name the projected IDs it derives, so adding the
///   plugin back derives the same ones and they resolve again.
/// - The authored rows the activation named as component overrides. Remove
///   deletes the activation, the only record that kept a workspace's own
///   override row out of its ambient scope; retired, the row stays listed
///   (the person can delete it) and stays out of scope until the plugin is
///   added back, when it is the component's override again.
///
/// Secret settings are not kept: Remove cleans their namespaces, and a later
/// Add starts with none, as it always has.
public struct RetiredPluginActivation: Codable, Equatable, Sendable {
    public var pluginID: String
    public var namespaceSeed: String
    public var overriddenComponentIDs: [String]
    public var overridingRowIDs: [String]

    public init(pluginID: String, namespaceSeed: String, overriddenComponentIDs: [String], overridingRowIDs: [String]) {
        self.pluginID = pluginID
        self.namespaceSeed = namespaceSeed
        self.overriddenComponentIDs = overriddenComponentIDs
        self.overridingRowIDs = overridingRowIDs
    }

    public init(_ activation: PluginActivation) {
        self.init(
            pluginID: activation.pluginID,
            namespaceSeed: activation.namespaceSeed,
            overriddenComponentIDs: activation.overriddenComponentIDs,
            overridingRowIDs: activation.overridingRowIDs
        )
    }

    var keepsAnything: Bool {
        !namespaceSeed.isEmpty || overridingRowIDs.contains { UUID(uuidString: $0) != nil }
    }

    /// Each kept override's component and row.
    var overrides: [(componentID: String, rowID: UUID)] {
        overriddenComponentIDs.enumerated().compactMap { index, componentID in
            guard index < overridingRowIDs.count, let row = UUID(uuidString: overridingRowIDs[index]) else { return nil }
            return (componentID, row)
        }
    }
}

extension WorkspaceCapabilityActivation {
    /// What Remove kept of the workspace's removed activations.
    public static func retiredActivations(of workspace: Workspace) -> [RetiredPluginActivation] {
        guard let json = workspace.retiredPluginActivationsJSON, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RetiredPluginActivation].self, from: data)) ?? []
    }

    /// The rows a removed activation named as overrides: kept out of the
    /// workspace's ambient scope (`overridingRowIDs(of:)`).
    public static func retiredOverrideRowIDs(of workspace: Workspace) -> Set<UUID> {
        Set(retiredActivations(of: workspace).flatMap { $0.overrides.map(\.rowID) })
    }

    /// Keeps `activation`'s seed and overrides before Remove deletes it,
    /// replacing what an earlier Remove of the same plugin kept.
    public static func retire(_ activation: PluginActivation, in workspace: Workspace) {
        var retired = retiredActivations(of: workspace).filter { $0.pluginID != activation.pluginID }
        let entry = RetiredPluginActivation(activation)
        if entry.keepsAnything { retired.append(entry) }
        setRetired(retired, on: workspace)
    }

    /// Gives a new activation of a removed plugin what its Remove kept: the
    /// seed, before anything derives an ID from it, and the overrides whose
    /// rows still exist (one the person deleted gives its component back to
    /// the plugin). Then forgets the record.
    public static func reinstateRetired(on activation: PluginActivation, in workspace: Workspace) {
        let all = retiredActivations(of: workspace)
        guard let entry = all.first(where: { $0.pluginID == activation.pluginID }) else { return }
        if activation.namespaceSeed.isEmpty, !entry.namespaceSeed.isEmpty {
            setNamespaceSeed(entry.namespaceSeed, on: activation)
        }
        for override in entry.overrides
        where !activation.overriddenComponentIDs.contains(override.componentID) && rowExists(override.rowID, near: workspace) {
            setOverridden(true, componentID: override.componentID, rowID: override.rowID, on: activation)
        }
        setRetired(all.filter { $0.pluginID != activation.pluginID }, on: workspace)
    }

    /// Restores what a workspace's own mirror kept, for plugins it has no
    /// activation of.
    public static func restoreRetired(_ entries: [RetiredPluginActivation], to workspace: Workspace) {
        let active = Set(activations(of: workspace).map(\.pluginID))
        let kept = retiredActivations(of: workspace).filter { entry in !entries.contains { $0.pluginID == entry.pluginID } }
        setRetired(kept + entries.filter { !active.contains($0.pluginID) && $0.keepsAnything }, on: workspace)
    }

    /// Copies the record onto `target`, a never-inserted launch copy, so its
    /// ambient scope leaves the same rows out.
    public static func copyRetired(from source: Workspace, to target: Workspace) {
        guard target.retiredPluginActivationsJSON != source.retiredPluginActivationsJSON else { return }
        target.retiredPluginActivationsJSON = source.retiredPluginActivationsJSON
    }

    static func setRetired(_ entries: [RetiredPluginActivation], on workspace: Workspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = entries.isEmpty ? nil : (try? encoder.encode(entries)).flatMap { String(data: $0, encoding: .utf8) }
        guard workspace.retiredPluginActivationsJSON != json else { return }
        workspace.retiredPluginActivationsJSON = json
    }

    private static func rowExists(_ id: UUID, near workspace: Workspace) -> Bool {
        if workspace.skills.contains(where: { $0.id == id && !$0.isDeleted })
            || workspace.localTools.contains(where: { $0.id == id && !$0.isDeleted }) { return true }
        guard let context = workspace.modelContext else { return false }
        var skills = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })
        skills.fetchLimit = 1
        if ((try? context.fetchCount(skills)) ?? 0) > 0 { return true }
        var tools = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == id })
        tools.fetchLimit = 1
        return ((try? context.fetchCount(tools)) ?? 0) > 0
    }
}
