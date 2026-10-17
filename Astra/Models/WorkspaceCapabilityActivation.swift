import Foundation
import SwiftData

/// The single owner of a workspace's capability enablement state.
///
/// Installed plugins are `PluginActivation` records (one per plugin and
/// workspace); packs and shared (global) skills, connectors and tools are
/// stored arrays on `Workspace`. Every write goes through `mutate`/`apply`/
/// `restore` and the activation helpers here, and
/// `CapabilityActivationOwnerFitnessTests` fails on a direct write anywhere
/// else.
///
/// Nothing here saves, posts notifications or bumps the workspace's
/// `updatedAt` on its own: callers keep their existing persistence and
/// timestamp handling, so routing a writer through the owner does not change
/// when or how it commits. Each activation the owner changes gets its
/// `revision` bumped, which is what derived caches key on.
public enum WorkspaceCapabilityActivation {
    /// Reads the enablement state. Plugin IDs and versions come from the
    /// workspace's activations, oldest first.
    public static func state(of workspace: Workspace) -> WorkspaceCapabilityActivationState {
        let activations = activations(of: workspace)
        return WorkspaceCapabilityActivationState(
            capabilityIDs: activations.filter(\.isEnabled).map(\.pluginID),
            packIDs: workspace.enabledPackIDs,
            globalSkillIDs: workspace.enabledGlobalSkillIDs,
            globalConnectorIDs: workspace.enabledGlobalConnectorIDs,
            globalToolIDs: workspace.enabledGlobalToolIDs,
            pluginIDs: activations.map(\.pluginID),
            pluginVersions: activations.map(\.recordedVersion)
        )
    }

    /// The workspace's live activations in a stable order (creation, then ID).
    public static func activations(of workspace: Workspace) -> [PluginActivation] {
        workspace.pluginActivations
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.pluginID < rhs.pluginID
            }
    }

    public static func activation(for pluginID: String, in workspace: Workspace) -> PluginActivation? {
        activations(of: workspace).first { $0.pluginID == pluginID }
    }

    /// Writes `state` back, touching only what changed. Assigning an equal
    /// value to a SwiftData property still notifies its observers, and every
    /// writer used to touch only the arrays it changed.
    ///
    /// A plugin in `pluginIDs` or `capabilityIDs` keeps (or gets) an
    /// activation, enabled when it is in `capabilityIDs`; an activation for a
    /// plugin in neither is deleted with its settings and bindings.
    public static func apply(_ state: WorkspaceCapabilityActivationState, to workspace: Workspace) {
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
        reconcileActivations(with: state, in: workspace)
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

    /// Changes one activation's settings, bindings or overrides, creating the
    /// activation (off) when the plugin has none here yet, and bumps its
    /// revision.
    @discardableResult
    public static func updateActivation<Result>(
        for pluginID: String,
        in workspace: Workspace,
        _ body: (PluginActivation) throws -> Result
    ) rethrows -> Result {
        let activation = activation(for: pluginID, in: workspace)
            ?? insertActivation(pluginID: pluginID, isEnabled: false, version: "", in: workspace, order: 0)
        let result = try body(activation)
        touch(activation)
        return result
    }

    /// Records the version and digest a workspace accepted for a plugin.
    public static func recordAccepted(
        pluginID: String,
        version: String,
        digest: String,
        in workspace: Workspace
    ) {
        updateActivation(for: pluginID, in: workspace) { activation in
            if activation.recordedVersion != version { activation.recordedVersion = version }
            if activation.recordedDigest != digest { activation.recordedDigest = digest }
        }
    }

    /// Sets one non-secret setting (`PluginActivation.settingKey`); nil
    /// removes it, so the plugin's default applies. An empty value is kept:
    /// it is the person clearing a setting whose default is not empty.
    public static func setConfigValue(_ value: String?, forKey key: String, on activation: PluginActivation) {
        var keys = activation.configKeys
        var values = activation.configValues
        while values.count < keys.count { values.append("") }
        if let index = keys.firstIndex(of: key) {
            if let value {
                values[index] = value
            } else {
                keys.remove(at: index)
                values.remove(at: index)
            }
        } else if let value {
            keys.append(key)
            values.append(value)
        }
        guard activation.configKeys != keys || activation.configValues != values else { return }
        if activation.configKeys != keys { activation.configKeys = keys }
        if activation.configValues != values { activation.configValues = values }
        touch(activation)
    }

    /// Records (or, with `stored` false, forgets) that a secret setting
    /// (`PluginActivation.settingKey`) has a value in the Keychain.
    public static func setSecretRecorded(_ stored: Bool, forKey key: String, on activation: PluginActivation) {
        var keys = activation.secretSettingKeys
        if stored {
            guard !keys.contains(key) else { return }
            keys.append(key)
        } else {
            guard keys.contains(key) else { return }
            keys.removeAll { $0 == key }
        }
        activation.secretSettingKeys = keys
        touch(activation)
    }

    /// Sets the seed mixed into the activation's projected IDs.
    public static func setNamespaceSeed(_ seed: String, on activation: PluginActivation) {
        guard activation.namespaceSeed != seed else { return }
        activation.namespaceSeed = seed
        touch(activation)
    }

    /// Records the components of the definition the activation was
    /// reconciled against.
    public static func setKnownComponents(_ componentIDs: [String], on activation: PluginActivation) {
        var unique: [String] = []
        for id in componentIDs where !unique.contains(id) { unique.append(id) }
        guard activation.knownComponentIDs != unique else { return }
        activation.knownComponentIDs = unique
        touch(activation)
    }

    /// Binds `account` to a connector component.
    ///
    /// A workspace has one default account per service, across all its
    /// plugins: the first account of a service bound in a workspace, or one
    /// bound with `isDefault`, becomes it. Account names (aliases) are unique
    /// per service among the accounts a workspace can see, so a task or the
    /// broker can name one; an account whose name another one there already
    /// has is renamed " 2", " 3" before it is bound.
    public static func bind(
        _ account: Connector,
        toComponent componentID: String,
        of activation: PluginActivation,
        isDefault: Bool = false
    ) {
        let existing = activation.bindings.filter { !$0.isDeleted && $0.componentID == componentID }
        let sameService = sameServiceBindings(as: account, in: activation)
        if let binding = existing.first(where: { $0.account?.id == account.id }) {
            if isDefault { makeDefault(binding, among: sameService) }
            touch(activation)
            return
        }
        disambiguateAlias(of: account, joining: activation)
        let hasDefault = sameService.contains { $0.isDefault && $0.account?.id != account.id }
        let accountIsDefault = sameService.contains { $0.isDefault && $0.account?.id == account.id }
        let binding = AccountBinding(componentID: componentID, isDefault: !hasDefault || isDefault || accountIsDefault)
        if let context = activation.modelContext {
            context.insert(binding)
        }
        binding.account = account
        binding.activation = activation
        if !activation.bindings.contains(where: { $0 === binding }) {
            activation.bindings.append(binding)
        }
        if binding.isDefault, isDefault || !hasDefault {
            makeDefault(binding, among: sameService + [binding])
        }
        touch(activation)
    }

    /// Removes the bindings of `account` from `activation` (only those of
    /// `componentID` when given). When that leaves the account's service
    /// without a default in the workspace, its oldest remaining account
    /// becomes it.
    public static func unbind(_ account: Connector, from activation: PluginActivation, componentID: String? = nil) {
        let removed = activation.bindings.filter {
            !$0.isDeleted && $0.account?.id == account.id && (componentID == nil || $0.componentID == componentID)
        }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        for binding in removed {
            activation.bindings.removeAll { $0 === binding }
            binding.modelContext?.delete(binding)
        }
        let remaining = sameServiceBindings(as: account, in: activation)
            .filter { !removedIDs.contains($0.id) }
        if !remaining.contains(where: \.isDefault),
           let first = remaining.min(by: { $0.createdAt < $1.createdAt }),
           let promoted = first.account {
            for binding in remaining where binding.account?.id == promoted.id {
                binding.isDefault = true
                if let owner = binding.activation, owner !== activation { touch(owner) }
            }
        }
        touch(activation)
    }

    /// The workspace's default account for `serviceType`, if one is bound.
    public static func defaultAccount(forService serviceType: String, in workspace: Workspace) -> Connector? {
        let service = normalizedService(serviceType)
        return activations(of: workspace)
            .flatMap(\.bindings)
            .first { !$0.isDeleted && $0.isDefault && normalizedService($0.account?.serviceType) == service }?
            .account
    }

    /// A name for an account of `serviceType` no other account of that
    /// service in the workspace has: `name`, else "name 2", "name 3".
    public static func uniqueAlias(
        _ name: String,
        serviceType: String,
        in workspace: Workspace,
        excluding accountID: UUID? = nil
    ) -> String {
        let taken = Set(visibleAccounts(ofService: serviceType, in: [workspace])
            .filter { $0.id != accountID }
            .map { normalizedAlias($0.name) })
        return uniqueName(name, avoiding: taken)
    }

    /// Marks a component as replaced by the authored row `rowID` (or, with
    /// `overridden` false, gives the component back to the plugin).
    public static func setOverridden(
        _ overridden: Bool,
        componentID: String,
        rowID: UUID? = nil,
        on activation: PluginActivation
    ) {
        var ids = activation.overriddenComponentIDs
        var rows = activation.overridingRowIDs
        while rows.count < ids.count { rows.append("") }
        if let index = ids.firstIndex(of: componentID) {
            ids.remove(at: index)
            rows.remove(at: index)
        }
        if overridden {
            ids.append(componentID)
            rows.append(rowID?.uuidString ?? "")
        }
        guard ids != activation.overriddenComponentIDs || rows != activation.overridingRowIDs else { return }
        activation.overriddenComponentIDs = ids
        activation.overridingRowIDs = rows
        touch(activation)
    }

    /// Moves everything an activation keeps for component `old` (settings,
    /// recorded secret keys, account bindings, an override) to component
    /// `new`, for a rename an Update declares. What `new` already has wins:
    /// its own setting keeps its value, an account bound to both stays bound
    /// once, and its own override stays.
    public static func moveComponentState(from old: String, to new: String, on activation: PluginActivation) {
        func renamed(_ key: String) -> String? {
            guard PluginActivation.componentID(ofSettingKey: key) == old else { return nil }
            return PluginActivation.settingKey(componentID: new, key: String(key.dropFirst(old.count + 1)))
        }
        var keys: [String] = []
        var values: [String] = []
        let destination = Set(activation.configKeys.filter { PluginActivation.componentID(ofSettingKey: $0) == new })
        for (index, key) in activation.configKeys.enumerated() {
            let value = index < activation.configValues.count ? activation.configValues[index] : ""
            let target = renamed(key) ?? key
            guard renamed(key) == nil || !destination.contains(target), !keys.contains(target) else { continue }
            keys.append(target)
            values.append(value)
        }
        if activation.configKeys != keys { activation.configKeys = keys }
        if activation.configValues != values { activation.configValues = values }
        var secrets: [String] = []
        for key in activation.secretSettingKeys {
            let target = renamed(key) ?? key
            if !secrets.contains(target) { secrets.append(target) }
        }
        if activation.secretSettingKeys != secrets { activation.secretSettingKeys = secrets }
        let newBindings = activation.bindings.filter { !$0.isDeleted && $0.componentID == new }
        for binding in activation.bindings where !binding.isDeleted && binding.componentID == old {
            if let id = binding.account?.id, let kept = newBindings.first(where: { $0.account?.id == id }) {
                // The account is bound to `new` already; it keeps the
                // default it had through `old`.
                if binding.isDefault { kept.isDefault = true }
                activation.bindings.removeAll { $0 === binding }
                binding.modelContext?.delete(binding)
            } else {
                binding.componentID = new
            }
        }
        if activation.overriddenComponentIDs.contains(old) {
            let row = activation.overridingRowID(forComponent: old)
            setOverridden(false, componentID: old, on: activation)
            if !activation.overriddenComponentIDs.contains(new) {
                setOverridden(true, componentID: new, rowID: row, on: activation)
            }
        }
        touch(activation)
    }

    /// Releases everything an activation keeps for a component its plugin
    /// no longer declares: settings, recorded secret keys, account bindings
    /// (the accounts stay) and an override (the authored row stays).
    public static func dropComponentState(_ componentID: String, on activation: PluginActivation) {
        dropSettings(on: activation) { PluginActivation.componentID(ofSettingKey: $0) == componentID }
        // Through `unbind`, so the workspace's default for the service moves
        // to a remaining account when the dropped binding held it.
        for binding in activation.bindings where !binding.isDeleted && binding.componentID == componentID {
            if let account = binding.account {
                unbind(account, from: activation, componentID: componentID)
            } else {
                activation.bindings.removeAll { $0 === binding }
                binding.modelContext?.delete(binding)
            }
        }
        setOverridden(false, componentID: componentID, on: activation)
        touch(activation)
    }

    /// Drops the settings (and recorded secret keys) of `componentID` whose
    /// keys its definition no longer declares.
    public static func dropSettings(
        of componentID: String,
        notIn declared: Set<String>,
        on activation: PluginActivation
    ) {
        let before = (activation.configKeys, activation.secretSettingKeys)
        dropSettings(on: activation) { key in
            PluginActivation.componentID(ofSettingKey: key) == componentID
                && !declared.contains(String(key.dropFirst(componentID.count + 1)))
        }
        if before != (activation.configKeys, activation.secretSettingKeys) { touch(activation) }
    }

    private static func dropSettings(on activation: PluginActivation, where shouldDrop: (String) -> Bool) {
        var keys: [String] = []
        var values: [String] = []
        for (index, key) in activation.configKeys.enumerated() where !shouldDrop(key) {
            keys.append(key)
            values.append(index < activation.configValues.count ? activation.configValues[index] : "")
        }
        if activation.configKeys != keys { activation.configKeys = keys }
        if activation.configValues != values { activation.configValues = values }
        let secrets = activation.secretSettingKeys.filter { !shouldDrop($0) }
        if activation.secretSettingKeys != secrets { activation.secretSettingKeys = secrets }
    }

    /// The enablement state, every activation's full record and the
    /// workspace's `updatedAt`, for undoing in-memory changes after a failed
    /// save.
    public struct Snapshot: Equatable, Sendable {
        public let state: WorkspaceCapabilityActivationState
        public let activations: [PluginActivationRecord]
        public let updatedAt: Date
    }

    public static func snapshot(_ workspace: Workspace) -> Snapshot {
        Snapshot(
            state: state(of: workspace),
            activations: activations(of: workspace).map(PluginActivationRecord.init),
            updatedAt: workspace.updatedAt
        )
    }

    public static func restore(_ snapshot: Snapshot, to workspace: Workspace) {
        apply(snapshot.state, to: workspace)
        let current = activations(of: workspace)
        let wanted = Set(snapshot.activations.map(\.id))
        for activation in current where !wanted.contains(activation.id) {
            remove(activation, from: workspace)
        }
        for record in snapshot.activations {
            let activation = activations(of: workspace).first { $0.id == record.id }
                ?? activations(of: workspace).first { $0.pluginID == record.pluginID }
                ?? insertActivation(
                    pluginID: record.pluginID,
                    isEnabled: record.isEnabled,
                    version: record.recordedVersion,
                    in: workspace,
                    order: 0,
                    id: record.id
                )
            record.restore(onto: activation)
        }
        workspace.updatedAt = snapshot.updatedAt
    }

    /// Copies every activation of `source` onto `target`, a never-inserted
    /// launch copy, with the same IDs (so projected skills keep their IDs and
    /// Keychain namespaces), settings and overrides. Bindings point at the
    /// copies in `accountsByID`; an account without a copy is left out.
    public static func copyActivations(
        from source: Workspace,
        to target: Workspace,
        accountsByID: [UUID: Connector]
    ) {
        for record in activations(of: source).map(PluginActivationRecord.init) {
            let activation = PluginActivation(
                id: record.id,
                pluginID: record.pluginID,
                isEnabled: record.isEnabled,
                recordedVersion: record.recordedVersion,
                recordedDigest: record.recordedDigest,
                createdAt: record.createdAt
            )
            activation.configKeys = record.configKeys
            activation.configValues = record.configValues
            activation.overriddenComponentIDs = record.overriddenComponentIDs
            activation.overridingRowIDs = record.overridingRowIDs
            activation.secretSettingKeys = record.secretSettingKeys
            activation.knownComponentIDs = record.knownComponentIDs
            activation.namespaceSeed = record.namespaceSeed
            activation.revision = record.revision
            activation.updatedAt = record.updatedAt
            activation.workspace = target
            for bindingRecord in record.bindings {
                guard let accountID = bindingRecord.accountID, let account = accountsByID[accountID] else { continue }
                let binding = AccountBinding(
                    id: bindingRecord.id,
                    componentID: bindingRecord.componentID,
                    isDefault: bindingRecord.isDefault,
                    createdAt: bindingRecord.createdAt
                )
                binding.account = account
                binding.activation = activation
            }
        }
    }

    // MARK: - Private

    private static func reconcileActivations(with state: WorkspaceCapabilityActivationState, in workspace: Workspace) {
        var desired: [String] = []
        for id in state.pluginIDs + state.capabilityIDs where !desired.contains(id) {
            desired.append(id)
        }
        let enabled = Set(state.capabilityIDs)
        var seen = Set<String>()
        for activation in activations(of: workspace) {
            if !desired.contains(activation.pluginID) || !seen.insert(activation.pluginID).inserted {
                remove(activation, from: workspace)
            }
        }
        for (order, pluginID) in desired.enumerated() {
            let versionIndex = state.pluginIDs.firstIndex(of: pluginID)
            let version = versionIndex.flatMap { $0 < state.pluginVersions.count ? state.pluginVersions[$0] : nil }
            guard let activation = activation(for: pluginID, in: workspace) else {
                insertActivation(
                    pluginID: pluginID,
                    isEnabled: enabled.contains(pluginID),
                    version: version ?? "",
                    in: workspace,
                    order: order
                )
                continue
            }
            var changed = false
            if activation.isEnabled != enabled.contains(pluginID) {
                activation.isEnabled = enabled.contains(pluginID)
                changed = true
            }
            if let version, activation.recordedVersion != version {
                activation.recordedVersion = version
                changed = true
            }
            if changed { touch(activation) }
        }
    }

    @discardableResult
    private static func insertActivation(
        pluginID: String,
        isEnabled: Bool,
        version: String,
        in workspace: Workspace,
        order: Int,
        id: UUID = UUID()
    ) -> PluginActivation {
        let latest = activations(of: workspace).map(\.createdAt).max() ?? .distantPast
        let createdAt = max(Date(), latest.addingTimeInterval(0.001)).addingTimeInterval(Double(order) * 0.001)
        let activation = PluginActivation(
            id: id,
            pluginID: pluginID,
            isEnabled: isEnabled,
            recordedVersion: version,
            createdAt: createdAt
        )
        if let context = workspace.modelContext {
            context.insert(activation)
        }
        activation.workspace = workspace
        if !workspace.pluginActivations.contains(where: { $0 === activation }) {
            workspace.pluginActivations.append(activation)
        }
        return activation
    }

    private static func remove(_ activation: PluginActivation, from workspace: Workspace) {
        workspace.pluginActivations.removeAll { $0 === activation }
        if let context = activation.modelContext {
            context.delete(activation)
        } else {
            activation.bindings.removeAll()
        }
    }

    /// Makes `binding`'s account the default: every binding of it is
    /// default, and every other account's binding among `bindings` is not.
    private static func makeDefault(_ binding: AccountBinding, among bindings: [AccountBinding]) {
        let accountID = binding.account?.id
        for other in bindings where other !== binding {
            let shouldBeDefault = accountID != nil && other.account?.id == accountID
            guard other.isDefault != shouldBeDefault else { continue }
            other.isDefault = shouldBeDefault
            if let owner = other.activation, owner !== binding.activation { touch(owner) }
        }
        if !binding.isDefault { binding.isDefault = true }
    }

    /// Bindings in `activation`'s workspace (or, without one, in the
    /// activation) whose account serves the same service as `account`.
    private static func sameServiceBindings(as account: Connector, in activation: PluginActivation) -> [AccountBinding] {
        let service = normalizedService(account.serviceType)
        let scope = activation.workspace.map { activations(of: $0) } ?? [activation]
        return scope
            .flatMap(\.bindings)
            .filter { !$0.isDeleted && normalizedService($0.account?.serviceType) == service }
    }

    /// Renames `account` when another account of its service that some
    /// workspace it will be visible in already sees has its name.
    private static func disambiguateAlias(of account: Connector, joining activation: PluginActivation) {
        var workspaces: [Workspace] = activation.workspace.map { [$0] } ?? []
        for binding in account.accountBindings where !binding.isDeleted {
            if let workspace = binding.activation?.workspace, !workspaces.contains(where: { $0 === workspace }) {
                workspaces.append(workspace)
            }
        }
        let others = visibleAccounts(ofService: account.serviceType, in: workspaces).filter { $0.id != account.id }
        let taken = Set(others.map { normalizedAlias($0.name) })
        guard taken.contains(normalizedAlias(account.name)) else { return }
        account.name = uniqueName(account.name, avoiding: taken)
        account.updatedAt = Date()
    }

    /// The accounts of a service the workspaces' plugins are bound to, plus
    /// the workspaces' own connector rows of that service.
    private static func visibleAccounts(ofService serviceType: String, in workspaces: [Workspace]) -> [Connector] {
        let service = normalizedService(serviceType)
        var seen = Set<UUID>()
        var accounts: [Connector] = []
        for workspace in workspaces {
            let bound = activations(of: workspace).flatMap(\.bindings).filter { !$0.isDeleted }.compactMap(\.account)
            for account in bound + workspace.connectors
            where !account.isDeleted && normalizedService(account.serviceType) == service && seen.insert(account.id).inserted {
                accounts.append(account)
            }
        }
        return accounts
    }

    private static func uniqueName(_ name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(normalizedAlias(name)) else { return name }
        var suffix = 2
        while taken.contains(normalizedAlias("\(name) \(suffix)")) { suffix += 1 }
        return "\(name) \(suffix)"
    }

    private static func normalizedService(_ serviceType: String?) -> String {
        (serviceType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedAlias(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func touch(_ activation: PluginActivation) {
        activation.revision += 1
        activation.updatedAt = Date()
    }
}

/// An activation's full content as a value, for snapshots and copies.
public struct PluginActivationRecord: Equatable, Sendable {
    public struct Binding: Equatable, Sendable {
        public let id: UUID
        public let componentID: String
        public let accountID: UUID?
        public let isDefault: Bool
        public let createdAt: Date
    }

    public let id: UUID
    public let pluginID: String
    public let isEnabled: Bool
    public let recordedVersion: String
    public let recordedDigest: String
    public let configKeys: [String]
    public let configValues: [String]
    public let overriddenComponentIDs: [String]
    public let overridingRowIDs: [String]
    public let secretSettingKeys: [String]
    public let knownComponentIDs: [String]
    public let namespaceSeed: String
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let bindings: [Binding]

    public init(_ activation: PluginActivation) {
        id = activation.id
        pluginID = activation.pluginID
        isEnabled = activation.isEnabled
        recordedVersion = activation.recordedVersion
        recordedDigest = activation.recordedDigest
        configKeys = activation.configKeys
        configValues = activation.configValues
        overriddenComponentIDs = activation.overriddenComponentIDs
        overridingRowIDs = activation.overridingRowIDs
        secretSettingKeys = activation.secretSettingKeys
        knownComponentIDs = activation.knownComponentIDs
        namespaceSeed = activation.namespaceSeed
        revision = activation.revision
        createdAt = activation.createdAt
        updatedAt = activation.updatedAt
        bindings = activation.bindings
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
            .map {
                Binding(
                    id: $0.id,
                    componentID: $0.componentID,
                    accountID: $0.account?.id,
                    isDefault: $0.isDefault,
                    createdAt: $0.createdAt
                )
            }
    }

    /// Writes this record onto `activation`. Bindings whose account no longer
    /// resolves (it was deleted) are dropped.
    func restore(onto activation: PluginActivation) {
        if activation.isEnabled != isEnabled { activation.isEnabled = isEnabled }
        if activation.recordedVersion != recordedVersion { activation.recordedVersion = recordedVersion }
        if activation.recordedDigest != recordedDigest { activation.recordedDigest = recordedDigest }
        if activation.configKeys != configKeys { activation.configKeys = configKeys }
        if activation.configValues != configValues { activation.configValues = configValues }
        if activation.overriddenComponentIDs != overriddenComponentIDs {
            activation.overriddenComponentIDs = overriddenComponentIDs
        }
        if activation.overridingRowIDs != overridingRowIDs {
            activation.overridingRowIDs = overridingRowIDs
        }
        if activation.secretSettingKeys != secretSettingKeys {
            activation.secretSettingKeys = secretSettingKeys
        }
        if activation.knownComponentIDs != knownComponentIDs {
            activation.knownComponentIDs = knownComponentIDs
        }
        if activation.namespaceSeed != namespaceSeed { activation.namespaceSeed = namespaceSeed }
        if activation.createdAt != createdAt { activation.createdAt = createdAt }
        let current = activation.bindings.filter { !$0.isDeleted }
        if current.map(Self.bindingKey) != bindings.map(Self.bindingKey) {
            let accountsByID = Dictionary(
                current.compactMap { binding in binding.account.map { ($0.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            for binding in current {
                activation.bindings.removeAll { $0 === binding }
                binding.modelContext?.delete(binding)
            }
            for record in bindings {
                guard let accountID = record.accountID,
                      let account = accountsByID[accountID] ?? Self.fetchConnector(accountID, near: activation) else { continue }
                let binding = AccountBinding(
                    id: record.id,
                    componentID: record.componentID,
                    isDefault: record.isDefault,
                    createdAt: record.createdAt
                )
                activation.modelContext?.insert(binding)
                binding.account = account
                binding.activation = activation
                if !activation.bindings.contains(where: { $0 === binding }) {
                    activation.bindings.append(binding)
                }
            }
        }
        if activation.revision != revision { activation.revision = revision }
        if activation.updatedAt != updatedAt { activation.updatedAt = updatedAt }
    }

    private static func bindingKey(_ binding: AccountBinding) -> String {
        "\(binding.id)|\(binding.componentID)|\(binding.account?.id.uuidString ?? "")|\(binding.isDefault)"
    }

    private static func bindingKey(_ binding: Binding) -> String {
        "\(binding.id)|\(binding.componentID)|\(binding.accountID?.uuidString ?? "")|\(binding.isDefault)"
    }

    private static func fetchConnector(_ id: UUID, near activation: PluginActivation) -> Connector? {
        guard let context = activation.modelContext else { return nil }
        var descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
