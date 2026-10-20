import Foundation
import ASTRACore
import ASTRAModels
import SwiftData

/// Derives a workspace's plugin skills, tools and accounts from its enabled
/// `PluginActivation`s and their library definitions.
///
/// No SwiftData row exists for a plugin's skill or tool. Each one is built
/// here as a never-inserted model whose ID is derived from the workspace, the
/// plugin and the component, so it is stable across launches and reinstalls
/// (schedules and templates that name it keep resolving), distinct per
/// workspace, and names the Keychain namespace that holds the component's
/// secret settings.
/// Its non-secret settings come from `PluginActivation.configValues`.
///
/// A connector component resolves to the connector rows bound to it
/// (`AccountBinding`), never to rows found by name or service type, so another
/// workspace's account is unreachable by construction.
///
/// Never assign a projected skill or tool to a managed model's relationship
/// (`task.skills`, `connector.skill`): SwiftData would insert it.
/// `isProjected(_:)` tells them apart.
struct PluginRuntimeProjection {
    enum ConnectorMode {
        /// The bound rows themselves, for views and services that edit them.
        case accounts
        /// Detached copies of the bound rows, each wired to its plugin's
        /// first skill like the shared rows used to be, for the runtime's
        /// skill-to-connector pairing.
        case runtimeCopies
    }

    let skills: [Skill]
    let tools: [LocalTool]
    let connectors: [Connector]
    /// Components the projection could not produce because the activation's
    /// connector component has no account bound yet, keyed by plugin ID.
    let unboundConnectorComponents: [String: [String]]
    /// Every plugin skill that owns each account, by account ID. An account
    /// two plugins bind is emitted once, wired to the first plugin's skill;
    /// scope pruning keeps it for any of its owners.
    var accountOwnerSkillIDs: [UUID: Set<UUID>] = [:]

    static let empty = PluginRuntimeProjection(skills: [], tools: [], connectors: [], unboundConnectorComponents: [:])

    /// Projects every enabled activation of `workspace` whose plugin is in
    /// `packages` (the caller's enabled, policy-allowed definitions), except
    /// one that awaits Update (`awaitsUpdate`).
    static func project(
        workspace: Workspace?,
        packages: [PluginPackage],
        connectorMode: ConnectorMode = .accounts
    ) -> PluginRuntimeProjection {
        guard let workspace, !packages.isEmpty else { return .empty }
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var skills: [Skill] = []
        var tools: [LocalTool] = []
        var connectors: [Connector] = []
        var unbound: [String: [String]] = [:]
        var seenConnectorIDs = Set<UUID>()
        var owners: [UUID: Set<UUID>] = [:]

        for activation in WorkspaceCapabilityActivation.activations(of: workspace) where activation.isEnabled {
            guard let package = packagesByID[activation.pluginID], !awaitsUpdate(activation, to: package) else { continue }
            let overridden = Set(activation.overriddenComponentIDs)
            // Only a projected skill is ever wired to projected resources: a
            // row assigned to a never-inserted model's relationship would
            // insert that model.
            var primarySkill: Skill?
            for (index, spec) in package.skills.enumerated() {
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                if overridden.contains(componentID) {
                    if let row = overridingSkill(for: componentID, of: activation, in: workspace) {
                        // The authored row that replaced the first skill
                        // still owns the plugin's resources. A stored row
                        // can't own a never-inserted one, so the runtime gets
                        // a detached copy, of every replacing row: a shared
                        // one may carry another workspace's attachments.
                        if row.modelContext == nil {
                            if index == 0 { primarySkill = row }
                            skills.append(row)
                        } else if connectorMode == .runtimeCopies {
                            let copy = TaskExecutionLaunchSnapshotApplicator.detachedSkill(row)
                            if index == 0 { primarySkill = copy }
                            skills.append(copy)
                            // The row's own attachments in this workspace
                            // come with it, wired to the copy.
                            for tool in row.localTools where !tool.isDeleted
                                && (tool.isGlobal || tool.workspace == nil || tool.workspace?.id == workspace.id) {
                                tools.append(TaskExecutionLaunchSnapshotApplicator.detachedLocalTool(tool, skill: copy))
                            }
                            for connector in attachedConnectors(of: row, in: workspace)
                            where seenConnectorIDs.insert(connector.id).inserted {
                                connectors.append(TaskExecutionLaunchSnapshotApplicator.detachedConnector(connector, skill: copy))
                            }
                        } else {
                            skills.append(row)
                        }
                        continue
                    }
                    if !overrideRowIsGone(in: workspace) { continue }
                }
                let skill = makeSkill(spec, package: package, activation: activation, componentID: componentID)
                if index == 0 { primarySkill = skill }
                skills.append(skill)
            }
            for spec in package.connectors {
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                guard !overridden.contains(componentID) else { continue }
                let accounts = activation.accounts(forComponent: componentID).filter { !$0.isDeleted }
                if accounts.isEmpty {
                    unbound[package.id, default: []].append(componentID)
                }
                if let primarySkill {
                    for account in accounts { owners[account.id, default: []].insert(primarySkill.id) }
                }
                for account in accounts where seenConnectorIDs.insert(account.id).inserted {
                    switch connectorMode {
                    case .accounts:
                        connectors.append(account)
                    case .runtimeCopies:
                        let copy = TaskExecutionLaunchSnapshotApplicator.detachedConnector(account, skill: primarySkill)
                        // A bound account is in scope through its binding,
                        // wherever the row itself lives, and runs under the
                        // name this workspace knows it by.
                        copy.isGlobal = true
                        copy.name = WorkspaceCapabilityActivation.alias(of: account, in: workspace)
                        connectors.append(copy)
                    }
                }
            }
            for spec in package.localTools {
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                if overridden.contains(componentID) {
                    if let row = overridingTool(for: componentID, of: activation, in: workspace) {
                        // A replacement no skill of this plugin owns (none,
                        // or one a workspace kept without the plugin) still
                        // belongs to its plugin: the runtime gets a copy wired
                        // to the first skill, so scope pruning keeps it with
                        // the plugin as it would the projected tool.
                        let ownedHere = row.skill.map { activation.overridingRowIDs.contains($0.id.uuidString) } ?? false
                        if connectorMode == .runtimeCopies, !ownedHere, let primarySkill {
                            tools.append(TaskExecutionLaunchSnapshotApplicator.detachedLocalTool(row, skill: primarySkill))
                        } else {
                            tools.append(row)
                        }
                        continue
                    }
                    if !overrideRowIsGone(in: workspace) { continue }
                }
                tools.append(makeTool(spec, package: package, activation: activation, componentID: componentID, skill: primarySkill))
            }
        }
        return PluginRuntimeProjection(
            skills: skills,
            tools: tools,
            connectors: connectors,
            unboundConnectorComponents: unbound,
            accountOwnerSkillIDs: owners
        )
    }

    /// The stable ID of a component's projected skill or tool in one
    /// workspace: a name-based UUID (version 5 layout) over the workspace,
    /// plugin and component IDs. Removing and adding the plugin again yields
    /// the same IDs; the Remove cleanup spares a namespace a live activation
    /// names again (`PluginSecretCleanupOutbox`).
    static func derivedID(workspaceID: UUID, pluginID: String, componentID: String, seed: String = "") -> UUID {
        PluginActivation.projectedID(workspaceID: workspaceID, pluginID: pluginID, componentID: componentID, seed: seed)
    }

    /// `derivedID` for a component of `activation`. An activation always has
    /// a workspace; one detached from it falls back to its own ID.
    static func derivedID(of activation: PluginActivation, componentID: String) -> UUID {
        derivedID(
            workspaceID: activation.launchWorkspaceID ?? activation.workspace?.id ?? activation.id,
            pluginID: activation.pluginID,
            componentID: componentID,
            seed: activation.namespaceSeed
        )
    }

    /// The component IDs a definition declares: skills, connectors, tools.
    static func componentIDs(of package: PluginPackage) -> [String] {
        package.skills.map { CapabilityResourceOrigin.componentID(for: $0) }
            + package.connectors.map { CapabilityResourceOrigin.componentID(for: $0) }
            + package.localTools.map { CapabilityResourceOrigin.componentID(for: $0) }
    }

    /// Every Keychain namespace an activation's components may hold secret
    /// settings under: the definition's skills when it is installed, plus
    /// every component the activation itself remembers (known components,
    /// settings, secrets, overrides), so cleanup does not depend on the
    /// library still having the plugin or the component.
    static func secretNamespaces(of activation: PluginActivation, package: PluginPackage?) -> [UUID] {
        var componentIDs = (package?.skills ?? []).map { CapabilityResourceOrigin.componentID(for: $0) }
        componentIDs += activation.knownComponentIDs
        componentIDs += activation.configKeys.compactMap(PluginActivation.componentID(ofSettingKey:))
        componentIDs += activation.secretSettingKeys.compactMap(PluginActivation.componentID(ofSettingKey:))
        componentIDs += activation.overriddenComponentIDs
        var seen = Set<String>()
        return componentIDs
            .filter { seen.insert($0).inserted }
            .map { derivedID(of: activation, componentID: $0) }
    }

    /// Whether `activation` accepted another definition of its plugin than
    /// `package`: the library holds one definition for every workspace, so
    /// an import, an Add elsewhere or the built-in sync replaces it here too.
    /// Until this workspace accepts it (Add again records the version,
    /// content digest and components), its plugin doesn't run here, in a
    /// run or a queued launch: a different version, different content under
    /// the same version (`PluginDefinitionDigest`, which leaves out where a
    /// copy came from, so two copies of one definition agree), or a
    /// component the activation never recorded. A digest recorded before
    /// content digests, or none (a mirror written before V20 carries only
    /// the version), can't be compared, so only the version and components
    /// are; an activation with no recorded version either has nothing to
    /// compare. Known components are compared as a superset because an Add
    /// keeps the ones a definition dropped, for secret cleanup.
    static func awaitsUpdate(_ activation: PluginActivation, to package: PluginPackage) -> Bool {
        if !activation.recordedVersion.isEmpty, activation.recordedVersion != package.version { return true }
        if PluginDefinitionDigest.matches(activation.recordedDigest, package) == false { return true }
        return !activation.knownComponentIDs.isEmpty
            && !Set(componentIDs(of: package)).isSubset(of: Set(activation.knownComponentIDs))
    }

    /// `packages` without the plugins whose activation in `workspace` awaits
    /// Update.
    static func runnable(_ packages: [PluginPackage], in workspace: Workspace) -> [PluginPackage] {
        packages.filter { package in
            WorkspaceCapabilityActivation.activation(for: package.id, in: workspace).map { !awaitsUpdate($0, to: package) } ?? true
        }
    }

    /// True for a skill this projection built rather than a stored row.
    static func isProjected(_ skill: Skill) -> Bool {
        skill.modelContext == nil && skill.originSourceKind == projectedSourceKind
    }

    static func isProjected(_ tool: LocalTool) -> Bool {
        tool.modelContext == nil && tool.originSourceKind == projectedSourceKind
    }

    /// Recorded as the origin source kind of projected resources.
    static let projectedSourceKind = "plugin_activation"

    // MARK: - Private

    /// An override whose row the store no longer has gives the component
    /// back to the plugin, so deleting the replacement never silently drops
    /// it. A detached launch can't tell (shared rows are not in its copy):
    /// it keeps skipping the component, and the launch carries the row.
    private static func overrideRowIsGone(in workspace: Workspace) -> Bool {
        workspace.modelContext != nil
    }

    /// The connectors attached to an override row that its workspace
    /// reaches through it: its own, or shared ones it turned on.
    private static func attachedConnectors(of row: Skill, in workspace: Workspace) -> [Connector] {
        let enabledShared = Set(WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs)
        return row.connectors.filter { connector in
            guard !connector.isDeleted else { return false }
            return connector.isGlobal
                ? enabledShared.contains(connector.id.uuidString)
                : connector.workspace?.id == workspace.id
        }
    }

    /// The authored row an override names: the workspace's own (or, in a
    /// detached launch, its copy), else a shared row from the store.
    private static func overridingSkill(
        for componentID: String,
        of activation: PluginActivation,
        in workspace: Workspace
    ) -> Skill? {
        guard let id = activation.overridingRowID(forComponent: componentID) else { return nil }
        if let row = workspace.skills.first(where: { $0.id == id && !$0.isDeleted }) { return row }
        guard let context = workspace.modelContext else { return nil }
        var descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func overridingTool(
        for componentID: String,
        of activation: PluginActivation,
        in workspace: Workspace
    ) -> LocalTool? {
        guard let id = activation.overridingRowID(forComponent: componentID) else { return nil }
        if let row = workspace.localTools.first(where: { $0.id == id && !$0.isDeleted }) { return row }
        guard let context = workspace.modelContext else { return nil }
        var descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func makeSkill(
        _ spec: PluginSkill,
        package: PluginPackage,
        activation: PluginActivation,
        componentID: String
    ) -> Skill {
        // Environment is assigned after init: the init's environment
        // parameter would move secret-looking values into the Keychain.
        let skill = Skill(
            name: spec.name,
            icon: spec.icon,
            skillDescription: spec.description,
            allowedTools: spec.allowedTools,
            disallowedTools: spec.disallowedTools,
            customTools: spec.customTools,
            behaviorInstructions: spec.behaviorInstructions
        )
        skill.id = derivedID(of: activation, componentID: componentID)
        let configured = activation.configuration(forComponent: componentID)
        skill.environmentKeys = spec.environmentKeys
        skill.environmentValues = spec.environmentKeys.enumerated().map { index, key in
            // Secret values live in the Keychain under this skill's ID.
            guard !Skill.isSecretEnvironmentKey(key) else { return "" }
            if let value = configured[key] { return value }
            return index < spec.environmentValues.count ? spec.environmentValues[index] : ""
        }
        skill.isGlobal = true
        CapabilityResourceOrigin.stamp(skill, package: package, componentID: componentID)
        skill.originSourceKind = projectedSourceKind
        skill.createdAt = activation.createdAt
        skill.updatedAt = activation.updatedAt
        return skill
    }

    private static func makeTool(
        _ spec: PluginLocalTool,
        package: PluginPackage,
        activation: PluginActivation,
        componentID: String,
        skill: Skill?
    ) -> LocalTool {
        let tool = LocalTool(
            name: spec.name,
            toolDescription: spec.description,
            icon: spec.icon,
            toolType: spec.toolType,
            command: spec.command,
            arguments: spec.arguments
        )
        tool.id = derivedID(of: activation, componentID: componentID)
        tool.isGlobal = true
        CapabilityResourceOrigin.stamp(tool, package: package, componentID: componentID)
        tool.originSourceKind = projectedSourceKind
        tool.createdAt = activation.createdAt
        tool.updatedAt = activation.updatedAt
        tool.skill = skill
        return tool
    }
}
