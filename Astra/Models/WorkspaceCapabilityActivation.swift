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

    /// Sets one non-secret setting (`componentID.KEY`); an empty value removes it.
    public static func setConfigValue(_ value: String, forKey key: String, on activation: PluginActivation) {
        var keys = activation.configKeys
        var values = activation.configValues
        while values.count < keys.count { values.append("") }
        if let index = keys.firstIndex(of: key) {
            if value.isEmpty {
                keys.remove(at: index)
                values.remove(at: index)
            } else {
                values[index] = value
            }
        } else if !value.isEmpty {
            keys.append(key)
            values.append(value)
        }
        if activation.configKeys != keys { activation.configKeys = keys }
        if activation.configValues != values { activation.configValues = values }
        touch(activation)
    }

    /// Binds `account` to a connector component. The first account bound to a
    /// component, or one bound with `isDefault`, becomes its default.
    public static func bind(
        _ account: Connector,
        toComponent componentID: String,
        of activation: PluginActivation,
        isDefault: Bool = false
    ) {
        let existing = activation.bindings.filter { !$0.isDeleted && $0.componentID == componentID }
        if let binding = existing.first(where: { $0.account?.id == account.id }) {
            if isDefault { makeDefault(binding, among: existing) }
            touch(activation)
            return
        }
        let binding = AccountBinding(componentID: componentID, isDefault: existing.isEmpty || isDefault)
        if let context = activation.modelContext {
            context.insert(binding)
        }
        binding.account = account
        binding.activation = activation
        if !activation.bindings.contains(where: { $0 === binding }) {
            activation.bindings.append(binding)
        }
        if binding.isDefault { makeDefault(binding, among: existing + [binding]) }
        touch(activation)
    }

    /// Removes every binding of `account` from `activation`, promoting the
    /// oldest remaining account of each component to default.
    public static func unbind(_ account: Connector, from activation: PluginActivation) {
        let removed = activation.bindings.filter { !$0.isDeleted && $0.account?.id == account.id }
        guard !removed.isEmpty else { return }
        for binding in removed {
            activation.bindings.removeAll { $0 === binding }
            binding.modelContext?.delete(binding)
        }
        for componentID in Set(removed.map(\.componentID)) {
            let remaining = activation.bindings
                .filter { !$0.isDeleted && $0.componentID == componentID }
                .sorted { $0.createdAt < $1.createdAt }
            if let first = remaining.first, !remaining.contains(where: \.isDefault) {
                first.isDefault = true
            }
        }
        touch(activation)
    }

    /// Marks a component as replaced by an authored row (or restores it).
    public static func setOverridden(_ overridden: Bool, componentID: String, on activation: PluginActivation) {
        var ids = activation.overriddenComponentIDs
        if overridden, !ids.contains(componentID) {
            ids.append(componentID)
        } else if !overridden {
            ids.removeAll { $0 == componentID }
        }
        guard ids != activation.overriddenComponentIDs else { return }
        activation.overriddenComponentIDs = ids
        touch(activation)
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

    private static func makeDefault(_ binding: AccountBinding, among bindings: [AccountBinding]) {
        for other in bindings where other !== binding && other.isDefault {
            other.isDefault = false
        }
        if !binding.isDefault { binding.isDefault = true }
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
