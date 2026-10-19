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
/// - The rows the V19 migration kept as authored for a plugin whose
///   definition was missing (`pendingOverrides`), recorded while its
///   activation is still live.
///
/// - The accounts its components created in this workspace
///   (`retainedAccounts`). Remove keeps an account and releases its
///   provenance, so nothing else would tell the next Add they are this
///   plugin's: Add binds each one back, stamped again, rather than making a
///   duplicate that needs the same sign-in again.
///
/// Secret settings are not kept: Remove cleans their namespaces, and a later
/// Add starts with none, as it always has.
public struct RetiredPluginActivation: Codable, Equatable, Sendable {
    /// An authored row and the plugin component it came from.
    public struct PendingOverride: Codable, Equatable, Sendable {
        public var componentID: String
        public var rowID: String
    }

    public var pluginID: String
    public var namespaceSeed: String
    public var overriddenComponentIDs: [String]
    public var overridingRowIDs: [String]
    /// Rows kept as the person's because nothing could compare them with the
    /// plugin's missing definition. Unlike the overrides above they stay in
    /// the workspace's scope, as authored rows; once the definition is back
    /// (Add, or a launch that finds it) each becomes its component's
    /// override (`adoptPendingOverrides`), so the plugin never projects a
    /// second copy next to it.
    public var pendingOverrides: [PendingOverride]?
    /// The workspace-owned accounts the plugin's components created, bound
    /// when it was removed.
    public var retainedAccounts: [RetainedAccount]?

    /// An account a component created, and whether it was its default.
    public struct RetainedAccount: Codable, Equatable, Sendable {
        public var componentID: String
        public var accountID: String
        public var isDefault: Bool
    }

    public init(
        pluginID: String,
        namespaceSeed: String,
        overriddenComponentIDs: [String],
        overridingRowIDs: [String],
        pendingOverrides: [PendingOverride]? = nil
    ) {
        self.pluginID = pluginID
        self.namespaceSeed = namespaceSeed
        self.overriddenComponentIDs = overriddenComponentIDs
        self.overridingRowIDs = overridingRowIDs
        self.pendingOverrides = pendingOverrides
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
        !namespaceSeed.isEmpty || overridingRowIDs.contains { UUID(uuidString: $0) != nil } || !(pendingOverrides ?? []).isEmpty
            || !(retainedAccounts ?? []).isEmpty
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
    /// replacing what an earlier Remove of the same plugin kept. Rows still
    /// pending as its overrides stay pending, for the next Add.
    public static func retire(_ activation: PluginActivation, in workspace: Workspace) {
        let all = retiredActivations(of: workspace)
        var retired = all.filter { $0.pluginID != activation.pluginID }
        var entry = RetiredPluginActivation(activation)
        entry.pendingOverrides = all.first { $0.pluginID == activation.pluginID }?.pendingOverrides
        // Read before Remove releases their provenance: a row this workspace
        // owns that the plugin stamped is one it created here.
        let retained = activation.bindings.filter { !$0.isDeleted }.compactMap { binding -> RetiredPluginActivation.RetainedAccount? in
            guard let account = binding.account, !account.isDeleted, !account.isGlobal,
                  account.workspace?.id == workspace.id, account.originPackageID == activation.pluginID else { return nil }
            return .init(componentID: binding.componentID, accountID: account.id.uuidString, isDefault: binding.isDefault)
        }
        entry.retainedAccounts = retained.isEmpty ? nil : retained
        if entry.keepsAnything { retired.append(entry) }
        setRetired(retired, on: workspace)
    }

    /// Records that the authored row `rowID` came from `componentID` of a
    /// plugin whose definition is missing (`pendingOverrides`).
    public static func recordPendingOverride(componentID: String, rowID: UUID, pluginID: String, in workspace: Workspace) {
        var all = retiredActivations(of: workspace)
        let pending = RetiredPluginActivation.PendingOverride(componentID: componentID, rowID: rowID.uuidString)
        if let index = all.firstIndex(where: { $0.pluginID == pluginID }) {
            guard !(all[index].pendingOverrides ?? []).contains(pending) else { return }
            all[index].pendingOverrides = (all[index].pendingOverrides ?? []) + [pending]
        } else {
            all.append(RetiredPluginActivation(
                pluginID: pluginID, namespaceSeed: "", overriddenComponentIDs: [], overridingRowIDs: [], pendingOverrides: [pending]
            ))
        }
        setRetired(all, on: workspace)
    }

    /// The accounts Remove kept for `pluginID` in `workspace` that still
    /// exist there, for Add to bind back (`retainedAccounts`).
    public static func retainedAccounts(of pluginID: String, in workspace: Workspace) -> [(componentID: String, account: Connector, isDefault: Bool)] {
        guard let entry = retiredActivations(of: workspace).first(where: { $0.pluginID == pluginID }) else { return [] }
        return (entry.retainedAccounts ?? []).compactMap { retained in
            guard let account = workspace.connectors.first(where: { !$0.isDeleted && $0.id.uuidString == retained.accountID })
            else { return nil }
            return (retained.componentID, account, retained.isDefault)
        }
    }

    /// The plugins whose kept rows are pending as overrides in `workspace`.
    public static func pendingOverridePluginIDs(of workspace: Workspace) -> Set<String> {
        Set(retiredActivations(of: workspace).filter { !($0.pendingOverrides ?? []).isEmpty }.map(\.pluginID))
    }

    /// Makes each row pending for `activation`'s plugin the override of the
    /// component it came from, now that the plugin's definition (declaring
    /// `componentIDs`) is available, and forgets the pending list. A row the
    /// person deleted, or whose component the definition doesn't declare,
    /// stays as it is: nothing would project it in its place. A shared row
    /// leaves the workspace's shared lists, as a migrated override does, so
    /// it is on exactly while the activation is.
    public static func adoptPendingOverrides(on activation: PluginActivation, declaring componentIDs: [String], in workspace: Workspace) {
        var all = retiredActivations(of: workspace)
        guard let index = all.firstIndex(where: { $0.pluginID == activation.pluginID }),
              let pending = all[index].pendingOverrides else { return }
        let declared = Set(componentIDs)
        for override in pending
        where declared.contains(override.componentID) && !activation.overriddenComponentIDs.contains(override.componentID) {
            guard let rowID = UUID(uuidString: override.rowID), rowExists(rowID, near: workspace) else { continue }
            setOverridden(true, componentID: override.componentID, rowID: rowID, on: activation)
            mutate(workspace) { state in
                state.globalSkillIDs.removeAll { $0 == override.rowID }
                state.globalToolIDs.removeAll { $0 == override.rowID }
            }
        }
        all[index].pendingOverrides = nil
        setRetired(all.filter(\.keepsAnything), on: workspace)
    }

    /// Gives a new activation of a removed plugin what its Remove kept: the
    /// seed, before anything derives an ID from it, and the overrides whose
    /// rows still exist (one the person deleted gives its component back to
    /// the plugin), as well as the rows pending as overrides of the
    /// components the definition declares (`componentIDs`). Then forgets the
    /// record.
    public static func reinstateRetired(on activation: PluginActivation, declaring componentIDs: [String], in workspace: Workspace) {
        adoptPendingOverrides(on: activation, declaring: componentIDs, in: workspace)
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

    /// Gives back each override of a component the definition `activation`
    /// just accepted (declaring `componentIDs`) no longer declares: nothing
    /// projects its row in the component's place any more, so the row is the
    /// workspace's own again rather than out of scope for good. A shared row
    /// goes back on the workspace's shared lists, which it left when it
    /// became the override, unless another override there still names it.
    public static func releaseUndeclaredOverrides(
        on activation: PluginActivation,
        declaring componentIDs: [String],
        in workspace: Workspace
    ) {
        let declared = Set(componentIDs)
        let released = activation.overriddenComponentIDs.enumerated().compactMap { index, componentID -> (String, UUID?)? in
            guard !declared.contains(componentID) else { return nil }
            return (componentID, index < activation.overridingRowIDs.count ? UUID(uuidString: activation.overridingRowIDs[index]) : nil)
        }
        guard !released.isEmpty else { return }
        for (componentID, _) in released {
            setOverridden(false, componentID: componentID, on: activation)
        }
        let stillOverriding = overridingRowIDs(of: workspace)
        for case let (_, rowID?) in released where !stillOverriding.contains(rowID) {
            guard let context = workspace.modelContext else { continue }
            var skills = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == rowID && $0.isGlobal == true })
            skills.fetchLimit = 1
            var tools = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == rowID && $0.isGlobal == true })
            tools.fetchLimit = 1
            if ((try? context.fetchCount(skills)) ?? 0) > 0 {
                mutate(workspace) { $0.enableGlobalSkill(rowID.uuidString) }
            } else if ((try? context.fetchCount(tools)) ?? 0) > 0 {
                mutate(workspace) { $0.enableGlobalTool(rowID.uuidString) }
            }
        }
    }

    /// Takes every row the workspace's activations, and removed ones, name
    /// as overrides off its shared lists: such a row is on exactly while its
    /// activation is, so a shared-list membership (a mirror import turns on
    /// every shared row it reads) would keep it on with the plugin off.
    public static func takeOverridesOffSharedLists(in workspace: Workspace) {
        let ids = Set(overridingRowIDs(of: workspace).map(\.uuidString))
        let state = state(of: workspace)
        guard state.globalSkillIDs.contains(where: ids.contains) || state.globalToolIDs.contains(where: ids.contains) else { return }
        mutate(workspace) { state in
            state.globalSkillIDs.removeAll(where: ids.contains)
            state.globalToolIDs.removeAll(where: ids.contains)
        }
    }

    /// Takes the shared accounts the workspace's activations bind off its
    /// shared list unless `listed` (what the mirror's own shared list named)
    /// has them. A mirror carries a bound account so the binding can be
    /// restored, and an import turns on every shared row it reads; left on,
    /// the account would stay in scope after an Update or Add releases it,
    /// though the person never turned it on. A mirror without a list names
    /// none, so its bound accounts come back binding-only.
    public static func takeBindingOnlyAccountsOffSharedList(in workspace: Workspace, listed: Set<String>) {
        let bound = Set(activations(of: workspace).flatMap(\.bindings).filter { !$0.isDeleted }
            .compactMap { $0.account?.id.uuidString })
            .subtracting(listed)
        guard state(of: workspace).globalConnectorIDs.contains(where: bound.contains) else { return }
        mutate(workspace) { $0.globalConnectorIDs.removeAll(where: bound.contains) }
    }

    /// Restores what a workspace's own mirror kept, for plugins it has no
    /// activation of; for one it has, only the rows still pending as its
    /// overrides.
    public static func restoreRetired(_ entries: [RetiredPluginActivation], to workspace: Workspace) {
        let active = Set(activations(of: workspace).map(\.pluginID))
        let kept = retiredActivations(of: workspace).filter { entry in !entries.contains { $0.pluginID == entry.pluginID } }
        let restored = entries.map { entry in
            guard active.contains(entry.pluginID) else { return entry }
            return RetiredPluginActivation(
                pluginID: entry.pluginID, namespaceSeed: "", overriddenComponentIDs: [], overridingRowIDs: [],
                pendingOverrides: entry.pendingOverrides
            )
        }
        setRetired(kept + restored.filter(\.keepsAnything), on: workspace)
    }

    /// Copies the record onto `target`, a never-inserted launch copy, so its
    /// ambient scope leaves the same rows out.
    public static func copyRetired(from source: Workspace, to target: Workspace) {
        guard target.retiredPluginActivationsJSON != source.retiredPluginActivationsJSON else { return }
        target.retiredPluginActivationsJSON = source.retiredPluginActivationsJSON
    }

    /// Gives `target`, a launch copy, the record a queued request froze
    /// (`entries`) instead of the live one: an Add while the request waited
    /// consumes the live record, and the rows it kept out of scope at
    /// submission must stay out of the run. Nil (a request that froze none)
    /// leaves the copy as it is.
    public static func applyFrozenRetired(_ entries: [RetiredPluginActivation]?, to target: Workspace) {
        guard let entries else { return }
        setRetired(entries, on: target)
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
