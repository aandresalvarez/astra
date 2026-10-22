import CryptoKit
import Foundation
import SwiftData
import ASTRACore

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

    /// The plugins on in `workspace`: its enabled activations, then each
    /// plugin its V19 enablement still lists without an activation. That
    /// list is cleared once `PluginActivationMigration` has moved it; one a
    /// failed migration rolled back (it retries on the next launch) keeps
    /// the plugins it lists on meanwhile, so what only a definition
    /// provides (MCP servers, browser adapters) stays available. Their
    /// skills, tools and accounts are still the V19 rows, which the rollback
    /// kept in scope. Writes never read it: `state(of:)` is activations only.
    public static func enabledPluginIDs(of workspace: Workspace) -> [String] {
        let enabled = state(of: workspace).capabilityIDs
        let legacy = workspace.legacyEnabledCapabilityIDs
        guard !legacy.isEmpty else { return enabled }
        var ids = enabled
        for id in legacy where !ids.contains(id) && activation(for: id, in: workspace) == nil {
            ids.append(id)
        }
        return ids
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

    /// Rows any of the workspace's activations, on or off, names as a
    /// component's override, and those a removed one named (retired by
    /// Remove until the plugin is added back or the row deleted). Such a row
    /// reaches a run only through its activation's projection, while that is
    /// on: never as one of the workspace's own, and never pinned to a task.
    public static func overridingRowIDs(of workspace: Workspace) -> Set<UUID> {
        Set(activations(of: workspace)
            .flatMap(\.overridingRowIDs)
            .compactMap(UUID.init(uuidString:)))
            .union(retiredOverrideRowIDs(of: workspace))
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

    /// Records the version and digest a workspace accepted for a plugin; an
    /// accepted definition is no longer awaited.
    public static func recordAccepted(
        pluginID: String,
        version: String,
        digest: String,
        in workspace: Workspace
    ) {
        updateActivation(for: pluginID, in: workspace) { activation in
            if activation.recordedVersion != version { activation.recordedVersion = version }
            if activation.recordedDigest != digest { activation.recordedDigest = digest }
            if activation.awaitingUpdate { activation.awaitingUpdate = false }
        }
    }

    /// Records (or clears) that an automatic reconcile held the activation
    /// back from its library definition. Returns whether it changed.
    @discardableResult
    public static func setAwaitingUpdate(_ awaiting: Bool, on activation: PluginActivation) -> Bool {
        guard activation.awaitingUpdate != awaiting else { return false }
        activation.awaitingUpdate = awaiting
        touch(activation)
        return true
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

    public static func setCredentialNamespaceSeed(_ seed: String, on activation: PluginActivation) {
        guard activation.credentialNamespaceSeed != seed else { return }
        activation.credentialNamespaceSeed = seed
        touch(activation)
    }

    /// Records each plugin template row's content digest (by component) as a
    /// sync wrote it.
    public static func setTemplateDigests(_ digests: [String: String], on activation: PluginActivation) {
        setTemplateDigests(entries: digests.sorted { $0.key < $1.key }.map { "\($0.key)#\($0.value)" }, on: activation)
    }

    /// Restores recorded `componentID#digest` entries as they were stored.
    public static func setTemplateDigests(entries: [String], on activation: PluginActivation) {
        guard activation.templateDigests != entries else { return }
        activation.templateDigests = entries
        touch(activation)
    }

    /// A digest of everything the person can edit on a plugin's template
    /// row: what a sync writes, and what only they set (model overrides,
    /// hooks, default skills), so an edit to either keeps the row theirs.
    public static func templateContentDigest(of row: TaskTemplate) -> String {
        let fields: [String] = [
            row.name, row.icon, row.templateDescription, row.beforeGoal, row.mainGoal, row.afterGoal,
            "\(row.beforeBudget)", "\(row.mainBudget)", "\(row.afterBudget)",
            row.variablesJSON, "\(row.passContextToMain)", "\(row.passContextToAfter)",
            row.beforeModel, row.mainModel, row.afterModel, row.hooksJSON
        ] + ["skills"] + row.defaultSkillIDs
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites a template row's default skills where ASTRA, not the
    /// person, moves a skill (a rename, a release, a migration, a validated
    /// import's fresh IDs). A plugin's row that was unedited stays unedited:
    /// the digest its activation records follows the rewrite.
    public static func rewriteDefaultSkills(of row: TaskTemplate, in workspace: Workspace?, _ rewrite: ([String]) -> [String]) {
        let rewritten = rewrite(row.defaultSkillIDs)
        guard rewritten != row.defaultSkillIDs else { return }
        let before = "\(row.originComponentID ?? "")#\(templateContentDigest(of: row))"
        row.defaultSkillIDs = rewritten
        guard let workspace, let packageID = row.originPackageID, let componentID = row.originComponentID,
              let activation = activation(for: packageID, in: workspace),
              activation.templateDigests.contains(before) else { return }
        let after = "\(componentID)#\(templateContentDigest(of: row))"
        setTemplateDigests(entries: activation.templateDigests.map { $0 == before ? after : $0 }, on: activation)
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
    /// has is renamed " 2", " 3" before it is bound. `createdAt` dates a
    /// new binding (a mirror restoring one keeps its age, which elects the
    /// next default); an existing binding keeps its own. A shared account
    /// another workspace uses keeps its name, and a collision here is
    /// recorded as the binding's alias instead (`alias(of:in:)`); `alias`
    /// restores one a mirror or launch record kept.
    public static func bind(
        _ account: Connector,
        toComponent componentID: String,
        of activation: PluginActivation,
        isDefault: Bool = false,
        createdAt: Date? = nil,
        alias: String? = nil
    ) {
        let existing = activation.bindings.filter { !$0.isDeleted && $0.componentID == componentID }
        let sameService = sameServiceBindings(as: account, in: activation)
        if let binding = existing.first(where: { $0.account?.id == account.id }) {
            if isDefault { makeDefault(binding, among: sameService) }
            touch(activation)
            return
        }
        // A name from a workspace file is cleaned the way every alias is.
        let bindingAlias = alias.flatMap(AccountDisplayName.sanitized)
            ?? existingAlias(of: account, in: activation) ?? disambiguateAlias(of: account, joining: activation)
        let hasDefault = sameService.contains { $0.isDefault && $0.account?.id != account.id }
        let accountIsDefault = sameService.contains { $0.isDefault && $0.account?.id == account.id }
        let binding = AccountBinding(
            componentID: componentID,
            isDefault: !hasDefault || isDefault || accountIsDefault,
            createdAt: createdAt ?? Date(),
            alias: bindingAlias
        )
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
    /// The workspaces whose activations bind `account`.
    public static func workspacesBinding(_ account: Connector) -> [Workspace] {
        var seen = Set<UUID>()
        return account.accountBindings
            .filter { !$0.isDeleted }
            .compactMap { $0.activation?.workspace }
            .filter { seen.insert($0.id).inserted }
    }

    /// The connector rows bound as accounts to any of the workspace's
    /// activations, on or off.
    public static func boundAccountIDs(of workspace: Workspace) -> Set<UUID> {
        Set(activations(of: workspace).flatMap(\.bindings).filter { !$0.isDeleted }.compactMap { $0.account?.id })
    }

    /// The accounts that reach `workspace` only through a binding, so they
    /// are in scope exactly while their plugin is on: every bound account
    /// but a shared one the workspace also lists on its own (the Shared
    /// Library, or a Plugins "Turn on"), which stays in scope through that
    /// list with its plugin off. A binding never puts an account on the
    /// list (`takeBindingOnlyAccountsOffSharedList`, `promoteToShared`), so
    /// a listed one was turned on independently. The runtime and the rail
    /// both leave these out of their authored paths.
    public static func bindingOnlyAccountIDs(of workspace: Workspace) -> Set<UUID> {
        let listed = Set(workspace.enabledGlobalConnectorIDs)
        return Set(activations(of: workspace).flatMap(\.bindings).filter { !$0.isDeleted }.compactMap(\.account)
            .filter { !($0.isGlobal && listed.contains($0.id.uuidString)) }
            .map(\.id))
    }

    /// Unbinds `account` from every activation, before it is deleted: the
    /// cascade would drop its bindings without electing a new default.
    public static func releaseAccount(_ account: Connector) {
        var seen = Set<UUID>()
        for activation in account.accountBindings.filter({ !$0.isDeleted }).compactMap(\.activation)
        where seen.insert(activation.id).inserted {
            unbind(account, from: activation)
        }
    }

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
        electDefault(among: remaining, excludingRevisionOf: activation)
        touch(activation)
    }

    /// Whether `account`'s service may change: not while a plugin binds it.
    /// A binding names a connector component, whose ID carries its service
    /// (`connector:<service>:<name>`), so a bound account of another service
    /// would be projected as that component's, and no binding crosses
    /// services. Unbind it first (Delete account, Remove, or an Update that
    /// drops the component).
    public static func canChangeService(of account: Connector) -> Bool {
        // OAuth grants keep their service identity through retirement and
        // in-flight renewal. Converting one in place would bypass that owner.
        account.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != OutlookCredentialIdentity.serviceType
            && !account.accountBindings.contains { !$0.isDeleted && $0.activation != nil }
    }

    /// Sets `account`'s service, refusing (false) while a plugin binds it
    /// (`canChangeService`).
    @discardableResult
    public static func changeService(of account: Connector, to serviceType: String) -> Bool {
        guard account.serviceType != serviceType else { return true }
        guard canChangeService(of: account) else { return false }
        account.serviceType = serviceType
        return true
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
            .map { normalizedAlias(self.alias(of: $0, in: workspace)) })
        return uniqueName(name, avoiding: taken)
    }

    /// The name `workspace` knows `account` by: its bindings' alias there,
    /// else the row's name.
    public static func alias(of account: Connector, in workspace: Workspace) -> String {
        activations(of: workspace).lazy
            .flatMap(\.bindings)
            .first { !$0.isDeleted && $0.account?.id == account.id && !$0.alias.isEmpty }?
            .alias ?? account.name
    }

    /// The alias another component of the same workspace already gave
    /// `account`, so one account has one name there.
    private static func existingAlias(of account: Connector, in activation: PluginActivation) -> String? {
        guard let workspace = activation.workspace else { return nil }
        let alias = self.alias(of: account, in: workspace)
        return alias == account.name ? nil : alias
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
                // default, the age and the name (`alias`) it had through `old`.
                if binding.isDefault { kept.isDefault = true }
                if binding.createdAt < kept.createdAt { kept.createdAt = binding.createdAt }
                if kept.alias.isEmpty, !binding.alias.isEmpty { kept.alias = binding.alias }
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

    /// The enablement state, every activation's full record, what Remove
    /// kept of removed ones and the workspace's `updatedAt`, for undoing
    /// in-memory changes after a failed save.
    public struct Snapshot: Equatable, Sendable {
        public let state: WorkspaceCapabilityActivationState
        public let activations: [PluginActivationRecord]
        public let retired: [RetiredPluginActivation]
        public let pendingLegacy: PendingLegacyState
        public let updatedAt: Date
    }

    public static func snapshot(_ workspace: Workspace) -> Snapshot {
        Snapshot(
            state: state(of: workspace),
            activations: activations(of: workspace).map(PluginActivationRecord.init),
            retired: retiredActivations(of: workspace),
            pendingLegacy: pendingLegacyState(of: workspace),
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
        setRetired(snapshot.retired, on: workspace)
        restorePendingLegacy(snapshot.pendingLegacy, to: workspace)
        if workspace.updatedAt != snapshot.updatedAt { workspace.updatedAt = snapshot.updatedAt }
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
        copyActivations(activations(of: source).map(PluginActivationRecord.init), of: source, to: target, accountsByID: accountsByID)
    }

    /// Copies `records` (activations `source` had when a request was
    /// submitted, or has now) onto `target`, as `copyActivations(from:)` does.
    ///
    /// `definitionsFrozen` says the request also retained the plugin's
    /// definition. Acceptance, settings, namespaces and bindings always come
    /// from the same record. Without that definition, projection compares the
    /// record with the current library and holds an incompatible request; a
    /// live Update must never stamp new acceptance onto old settings. An
    /// explicit live hold also applies to legacy requests without definitions.
    ///
    /// An override whose row's contents the request froze (`frozenRowIDs`)
    /// is kept even when the store no longer has the row.
    public static func copyActivations(
        _ records: [PluginActivationRecord],
        of source: Workspace,
        to target: Workspace,
        accountsByID: [UUID: Connector],
        definitionsFrozen: Bool = false,
        frozenRowIDs: Set<UUID> = []
    ) {
        for record in records {
            let liveHold = !definitionsFrozen && activations(of: source).contains { $0.id == record.id && $0.awaitingUpdate }
            let activation = PluginActivation(
                id: record.id,
                pluginID: record.pluginID,
                isEnabled: record.isEnabled,
                recordedVersion: record.recordedVersion,
                recordedDigest: record.recordedDigest,
                createdAt: record.createdAt
            )
            activation.launchWorkspaceID = record.workspaceID ?? source.id
            activation.configKeys = record.configKeys
            activation.configValues = record.configValues
            // A launch copy can't tell a deleted override row from a shared
            // one it didn't copy, so overrides whose row the store no longer
            // has are dropped here, where the store can still say: the copy
            // projects the plugin's component, as the live workspace does.
            let live = liveOverrides(record, in: source, frozenRowIDs: frozenRowIDs)
            activation.overriddenComponentIDs = live.map(\.componentID)
            activation.overridingRowIDs = live.map(\.rowID)
            activation.secretSettingKeys = record.secretSettingKeys
            activation.knownComponentIDs = record.knownComponentIDs
            activation.templateDigests = record.templateDigests
            activation.awaitingUpdate = record.awaitingUpdate || liveHold
            activation.namespaceSeed = record.namespaceSeed
            activation.credentialNamespaceSeed = record.credentialNamespaceSeed
            activation.revision = record.revision
            activation.updatedAt = record.updatedAt
            activation.workspace = target
            for bindingRecord in record.bindings {
                guard let accountID = bindingRecord.accountID, let account = accountsByID[accountID] else { continue }
                let binding = AccountBinding(
                    id: bindingRecord.id,
                    componentID: bindingRecord.componentID,
                    isDefault: bindingRecord.isDefault,
                    createdAt: bindingRecord.createdAt,
                    alias: bindingRecord.alias ?? ""
                )
                binding.account = account
                binding.activation = activation
            }
        }
    }

    // MARK: - Private

    /// The overrides of `record` whose authored row still exists in the
    /// store `workspace` is in, or was frozen; all of them when there is no
    /// store to ask.
    private static func liveOverrides(
        _ record: PluginActivationRecord,
        in workspace: Workspace,
        frozenRowIDs: Set<UUID>
    ) -> [(componentID: String, rowID: String)] {
        let pairs = record.overriddenComponentIDs.enumerated().map { index, componentID in
            (componentID: componentID, rowID: index < record.overridingRowIDs.count ? record.overridingRowIDs[index] : "")
        }
        guard let context = workspace.modelContext else { return pairs }
        return pairs.filter { pair in
            guard let id = UUID(uuidString: pair.rowID) else { return false }
            if frozenRowIDs.contains(id) { return true }
            var skills = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })
            skills.fetchLimit = 1
            if ((try? context.fetchCount(skills)) ?? 1) > 0 { return true }
            var tools = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == id })
            tools.fetchLimit = 1
            return ((try? context.fetchCount(tools)) ?? 1) > 0
        }
    }

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
        let accounts = activation.bindings.filter { !$0.isDeleted }.compactMap(\.account)
        if let context = activation.modelContext {
            // Let the declared cascade delete the bindings. Unbinding first
            // rewrites the doomed owner's revision and relationships; older
            // SwiftData can resurrect that intermediate state after rollback.
            let services = Set(accounts.map { normalizedService($0.serviceType) })
            context.delete(activation)
            workspace.pluginActivations.removeAll { $0 === activation }
            let remaining = activations(of: workspace).flatMap(\.bindings).filter { !$0.isDeleted }
            for service in services {
                electDefault(among: remaining.filter { normalizedService($0.account?.serviceType) == service })
            }
        } else {
            // Detached launch graphs have no store to perform a cascade.
            var seen = Set<UUID>()
            for account in accounts where seen.insert(account.id).inserted {
                unbind(account, from: activation)
            }
            workspace.pluginActivations.removeAll { $0 === activation }
            activation.bindings.removeAll()
        }
    }

    private static func electDefault(among bindings: [AccountBinding], excludingRevisionOf activation: PluginActivation? = nil) {
        guard !bindings.contains(where: \.isDefault),
              let first = bindings.min(by: { $0.createdAt < $1.createdAt }),
              let promoted = first.account else { return }
        for binding in bindings where binding.account?.id == promoted.id {
            binding.isDefault = true
            if let owner = binding.activation, owner !== activation { touch(owner) }
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
    /// workspace it will be visible in already sees has its name; returns
    /// the binding alias for one that can't be renamed ("" when none).
    private static func disambiguateAlias(of account: Connector, joining activation: PluginActivation) -> String {
        // An account another workspace already uses keeps its name: renaming
        // the shared row would change its alias there too. A collision in
        // the joining workspace gets an alias on this binding instead.
        let joining = activation.workspace
        func bindingAlias() -> String {
            guard let joining else { return "" }
            let alias = uniqueAlias(account.name, serviceType: account.serviceType, in: joining, excluding: account.id)
            return alias == account.name ? "" : alias
        }
        if account.accountBindings.contains(where: { binding in
            guard !binding.isDeleted, let other = binding.activation?.workspace else { return false }
            return other !== joining
        }) { return bindingAlias() }
        // So does a shared row another workspace turned on by itself: it has
        // no binding there, but its name is the one that workspace uses.
        if account.isGlobal, let context = account.modelContext ?? activation.modelContext {
            let id = account.id.uuidString
            let usedElsewhere = (try? context.fetch(FetchDescriptor<Workspace>())).map { workspaces in
                workspaces.contains { $0.id != joining?.id && $0.enabledGlobalConnectorIDs.contains(id) }
            } ?? true
            if usedElsewhere { return bindingAlias() }
        }
        var workspaces: [Workspace] = activation.workspace.map { [$0] } ?? []
        for binding in account.accountBindings where !binding.isDeleted {
            if let workspace = binding.activation?.workspace, !workspaces.contains(where: { $0 === workspace }) {
                workspaces.append(workspace)
            }
        }
        let others = visibleAccounts(ofService: account.serviceType, in: workspaces).filter { $0.id != account.id }
        let taken = Set(others.map { normalizedAlias($0.name) })
            .union(joining.map { workspace in others.map { normalizedAlias(alias(of: $0, in: workspace)) } } ?? [])
        guard taken.contains(normalizedAlias(account.name)) else { return "" }
        account.name = uniqueName(account.name, avoiding: taken)
        account.updatedAt = Date()
        return ""
    }

    /// The accounts of a service the workspaces' plugins are bound to, the
    /// workspaces' own connector rows of that service, and the shared rows
    /// they list on their own: a listed shared account is in the
    /// workspace's scope too, so its name selects it there.
    private static func visibleAccounts(ofService serviceType: String, in workspaces: [Workspace]) -> [Connector] {
        let service = normalizedService(serviceType)
        var seen = Set<UUID>()
        var accounts: [Connector] = []
        for workspace in workspaces {
            let bound = activations(of: workspace).flatMap(\.bindings).filter { !$0.isDeleted }.compactMap(\.account)
            for account in bound + workspace.connectors + listedSharedAccounts(of: workspace)
            where !account.isDeleted && normalizedService(account.serviceType) == service && seen.insert(account.id).inserted {
                accounts.append(account)
            }
        }
        return accounts
    }

    /// The shared rows `workspace`'s shared list names. A launch copy (no
    /// context) has none of them.
    private static func listedSharedAccounts(of workspace: Workspace) -> [Connector] {
        let listed = Set(workspace.enabledGlobalConnectorIDs.compactMap(UUID.init(uuidString:)))
        guard !listed.isEmpty, let context = workspace.modelContext else { return [] }
        let shared = (try? context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))) ?? []
        return shared.filter { listed.contains($0.id) }
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

/// An activation's full content as a value, for snapshots and copies, and
/// for the launch snapshot a queued request carries (`TaskTurnRequest`).
public struct PluginActivationRecord: Codable, Equatable, Sendable {
    public struct Binding: Codable, Equatable, Sendable {
        public let id: UUID
        public let componentID: String
        public let accountID: UUID?
        public let isDefault: Bool
        public let createdAt: Date
        /// The binding's alias (`AccountBinding.alias`); nil when none, and
        /// in a record written before it was kept.
        public let alias: String?
    }

    public let id: UUID
    /// Namespace identity at submission, even if the task later moves workspaces.
    public let workspaceID: UUID?
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
    public let templateDigests: [String]
    public let awaitingUpdate: Bool
    public let namespaceSeed: String
    public let credentialNamespaceSeed: String
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let bindings: [Binding]

    /// A field added after records were first frozen into queued requests
    /// decodes as empty when absent, so a request an earlier build queued
    /// still launches with its snapshot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        recordedVersion = try container.decode(String.self, forKey: .recordedVersion)
        recordedDigest = try container.decode(String.self, forKey: .recordedDigest)
        configKeys = try container.decode([String].self, forKey: .configKeys)
        configValues = try container.decode([String].self, forKey: .configValues)
        overriddenComponentIDs = try container.decode([String].self, forKey: .overriddenComponentIDs)
        overridingRowIDs = try container.decode([String].self, forKey: .overridingRowIDs)
        secretSettingKeys = try container.decodeIfPresent([String].self, forKey: .secretSettingKeys) ?? []
        knownComponentIDs = try container.decodeIfPresent([String].self, forKey: .knownComponentIDs) ?? []
        templateDigests = try container.decodeIfPresent([String].self, forKey: .templateDigests) ?? []
        awaitingUpdate = try container.decodeIfPresent(Bool.self, forKey: .awaitingUpdate) ?? false
        namespaceSeed = try container.decodeIfPresent(String.self, forKey: .namespaceSeed) ?? ""
        credentialNamespaceSeed = try container.decodeIfPresent(String.self, forKey: .credentialNamespaceSeed) ?? ""
        revision = try container.decode(Int.self, forKey: .revision)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        bindings = try container.decode([Binding].self, forKey: .bindings)
    }

    public init(_ activation: PluginActivation) {
        self.init(activation, configuration: (activation.configKeys, activation.configValues))
    }

    /// A queued request carries credential references, never legacy plaintext.
    public static func forLaunch(_ activation: PluginActivation) -> Self {
        Self(activation, configuration: PluginLaunchConfiguration.activation(activation))
    }

    private init(_ activation: PluginActivation, configuration: (keys: [String], values: [String])) {
        id = activation.id
        workspaceID = activation.launchWorkspaceID ?? activation.workspace?.id
        pluginID = activation.pluginID
        isEnabled = activation.isEnabled
        recordedVersion = activation.recordedVersion
        recordedDigest = activation.recordedDigest
        configKeys = configuration.keys
        configValues = configuration.values
        overriddenComponentIDs = activation.overriddenComponentIDs
        overridingRowIDs = activation.overridingRowIDs
        secretSettingKeys = activation.secretSettingKeys
        knownComponentIDs = activation.knownComponentIDs
        templateDigests = activation.templateDigests
        awaitingUpdate = activation.awaitingUpdate
        namespaceSeed = activation.namespaceSeed
        credentialNamespaceSeed = activation.credentialNamespaceSeed
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
                    createdAt: $0.createdAt,
                    alias: $0.alias.isEmpty ? nil : $0.alias
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
        if activation.templateDigests != templateDigests { activation.templateDigests = templateDigests }
        if activation.awaitingUpdate != awaitingUpdate { activation.awaitingUpdate = awaitingUpdate }
        if activation.namespaceSeed != namespaceSeed { activation.namespaceSeed = namespaceSeed }
        if activation.credentialNamespaceSeed != credentialNamespaceSeed { activation.credentialNamespaceSeed = credentialNamespaceSeed }
        if activation.createdAt != createdAt { activation.createdAt = createdAt }
        restoreBindings(onto: activation)
        if activation.revision != revision { activation.revision = revision }
        if activation.updatedAt != updatedAt { activation.updatedAt = updatedAt }
    }

    /// Binding identity is its durable ID, not its mutable default, alias or
    /// component. Restoring an attribute must not replace surviving rows:
    /// another rollback would discard those replacements on older SwiftData.
    private func restoreBindings(onto activation: PluginActivation) {
        let current = activation.bindings.filter { !$0.isDeleted }
        let wanted = Set(bindings.map(\.id))
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let accountsByID = Dictionary(current.compactMap { binding in binding.account.map { ($0.id, $0) } },
                                      uniquingKeysWith: { first, _ in first })
        for binding in current where !wanted.contains(binding.id) {
            activation.bindings.removeAll { $0 === binding }
            binding.modelContext?.delete(binding)
        }
        for record in bindings {
            let account: Connector?
            if let id = record.accountID {
                guard let saved = accountsByID[id] ?? Self.fetchConnector(id, near: activation) else { continue }
                account = saved
            } else {
                account = nil
            }
            let binding: AccountBinding
            if let existing = currentByID[record.id] {
                binding = existing
            } else {
                binding = AccountBinding(id: record.id, componentID: record.componentID,
                    isDefault: record.isDefault, createdAt: record.createdAt, alias: record.alias ?? "")
                activation.modelContext?.insert(binding)
                binding.activation = activation
                if !activation.bindings.contains(where: { $0 === binding }) { activation.bindings.append(binding) }
            }
            if binding.componentID != record.componentID { binding.componentID = record.componentID }
            if binding.isDefault != record.isDefault { binding.isDefault = record.isDefault }
            if binding.alias != (record.alias ?? "") { binding.alias = record.alias ?? "" }
            if binding.createdAt != record.createdAt { binding.createdAt = record.createdAt }
            if binding.account?.id != account?.id { binding.account = account }
        }
    }

    private static func fetchConnector(_ id: UUID, near activation: PluginActivation) -> Connector? {
        guard let context = activation.modelContext else { return nil }
        var descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// A plugin account's non-secret contents, frozen with a queued request so an
/// account edited or deleted while the request waits does not change what it
/// runs with. Never a credential value: those stay in the Keychain, read by
/// the account's ID at launch. (`credentialValues` is the legacy plaintext
/// column, so it is never captured.)
public struct PluginAccountRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let credentialNamespaceID: UUID?
    public let outlookCredentialFormat: String?
    public let name: String
    public let serviceType: String
    public let icon: String
    public let connectorDescription: String
    public let baseURL: String
    public let authMethod: String
    public let credentialKeys: [String]
    public let configKeys: [String]
    public let configValues: [String]
    public let isGlobal: Bool
    public let testHTTPMethod: String
    public let notes: String
    public let originPackageID: String?
    public let originPackageVersion: String?
    public let originComponentID: String?
    public let originComponentKind: String?
    public let originSourceKind: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(_ account: Connector) {
        self.init(account, configuration: (account.configKeys, account.configValues))
    }

    public static func forLaunch(_ account: Connector) -> Self {
        Self(account, configuration: PluginLaunchConfiguration.account(account))
    }

    private init(_ account: Connector, configuration: (keys: [String], values: [String])) {
        id = account.id
        credentialNamespaceID = account.credentialNamespaceID
        outlookCredentialFormat = account.outlookCredentialFormat
        name = account.name
        serviceType = account.serviceType
        icon = account.icon
        connectorDescription = account.connectorDescription
        baseURL = account.baseURL
        authMethod = account.authMethod
        credentialKeys = account.credentialKeys
        configKeys = configuration.keys
        configValues = configuration.values
        isGlobal = account.isGlobal
        testHTTPMethod = account.testHTTPMethod
        notes = account.notes
        originPackageID = account.originPackageID
        originPackageVersion = account.originPackageVersion
        originComponentID = account.originComponentID
        originComponentKind = account.originComponentKind
        originSourceKind = account.originSourceKind
        createdAt = account.createdAt
        updatedAt = account.updatedAt
    }

    /// The accounts `workspace`'s enabled activations bind, once each.
    public static func boundAccounts(of workspace: Workspace) -> [PluginAccountRecord] {
        var seen = Set<UUID>()
        return WorkspaceCapabilityActivation.activations(of: workspace)
            .filter(\.isEnabled)
            .flatMap(\.bindings)
            .filter { !$0.isDeleted }
            .compactMap(\.account)
            .filter { !$0.isDeleted && seen.insert($0.id).inserted }
            .map(PluginAccountRecord.forLaunch)
    }

    /// Writes these contents onto `account`, a launch copy (never a stored
    /// row): its credential values are left as they are.
    public func apply(to account: Connector) {
        account.credentialNamespaceID = credentialNamespaceID
        account.name = name
        account.serviceType = serviceType
        account.icon = icon
        account.connectorDescription = connectorDescription
        account.baseURL = baseURL
        account.authMethod = authMethod
        account.credentialKeys = credentialKeys
        account.configKeys = configKeys
        account.configValues = configValues
        if let outlookCredentialFormat { account.outlookCredentialFormat = outlookCredentialFormat }
        account.isGlobal = isGlobal
        account.testHTTPMethod = testHTTPMethod
        account.notes = notes
        account.originPackageID = originPackageID
        account.originPackageVersion = originPackageVersion
        account.originComponentID = originComponentID
        account.originComponentKind = originComponentKind
        account.originSourceKind = originSourceKind
        account.createdAt = createdAt
        account.updatedAt = updatedAt
    }

    /// A never-inserted account with these contents, for one deleted since.
    public func makeAccount() -> Connector {
        let account = Connector()
        account.id = id
        apply(to: account)
        return account
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
