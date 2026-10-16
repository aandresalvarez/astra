import CryptoKit
import Foundation
import ASTRACore
import ASTRAModels
import SwiftData

/// Derives a workspace's plugin skills, tools and accounts from its enabled
/// `PluginActivation`s and their library definitions.
///
/// No SwiftData row exists for a plugin's skill or tool. Each one is built
/// here as a never-inserted model whose ID is derived from the activation and
/// the component, so it is stable across launches, distinct per workspace, and
/// names the Keychain namespace that holds the component's secret settings.
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

    static let empty = PluginRuntimeProjection(skills: [], tools: [], connectors: [], unboundConnectorComponents: [:])

    /// Projects every enabled activation of `workspace` whose plugin is in
    /// `packages` (the caller's enabled, policy-allowed definitions).
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

        for activation in WorkspaceCapabilityActivation.activations(of: workspace) where activation.isEnabled {
            guard let package = packagesByID[activation.pluginID] else { continue }
            let overridden = Set(activation.overriddenComponentIDs)
            // Only a projected skill is ever wired to projected resources: a
            // row assigned to a never-inserted model's relationship would
            // insert that model.
            var primarySkill: Skill?
            for (index, spec) in package.skills.enumerated() {
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                guard !overridden.contains(componentID) else {
                    if let row = overridingSkill(for: componentID, of: activation, in: workspace) {
                        skills.append(row)
                    }
                    continue
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
                for account in accounts where seenConnectorIDs.insert(account.id).inserted {
                    switch connectorMode {
                    case .accounts:
                        connectors.append(account)
                    case .runtimeCopies:
                        let copy = TaskExecutionLaunchSnapshotApplicator.detachedConnector(account, skill: primarySkill)
                        // A bound account is in scope through its binding,
                        // wherever the row itself lives.
                        copy.isGlobal = true
                        connectors.append(copy)
                    }
                }
            }
            for spec in package.localTools {
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                guard !overridden.contains(componentID) else {
                    if let row = overridingTool(for: componentID, of: activation, in: workspace) {
                        tools.append(row)
                    }
                    continue
                }
                tools.append(makeTool(spec, package: package, activation: activation, componentID: componentID, skill: primarySkill))
            }
        }
        return PluginRuntimeProjection(
            skills: skills,
            tools: tools,
            connectors: connectors,
            unboundConnectorComponents: unbound
        )
    }

    /// The stable ID of a component's projected skill or tool in one
    /// activation: a name-based UUID (version 5 layout) over both IDs.
    static func derivedID(activationID: UUID, componentID: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("astra.plugin-component|".utf8))
        hasher.update(data: Data(activationID.uuidString.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(componentID.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
        skill.id = derivedID(activationID: activation.id, componentID: componentID)
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
        tool.id = derivedID(activationID: activation.id, componentID: componentID)
        tool.isGlobal = true
        CapabilityResourceOrigin.stamp(tool, package: package, componentID: componentID)
        tool.originSourceKind = projectedSourceKind
        tool.createdAt = activation.createdAt
        tool.updatedAt = activation.updatedAt
        tool.skill = skill
        return tool
    }
}
