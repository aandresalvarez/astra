import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Moves a V19 store's plugin state onto `PluginActivation` (Plugins 2.0 R1).
///
/// Runs once the V20 store is open, before anything resolves capabilities,
/// and again on any later launch that still finds legacy state, so an
/// interrupted run finishes. It is idempotent: a store with no legacy
/// enablement arrays and no plugin-origin skill or tool rows is left alone.
///
/// - Each workspace gets one activation per plugin in its legacy installed or
///   enabled lists, on when it was enabled, with the recorded version and the
///   library digest.
/// - A plugin-origin connector stays a row and becomes an account: a
///   workspace-owned one is bound to its workspace's activation, a shared one
///   to every activation of its plugin. Credentials stored only under the
///   stable namespace are copied into the row's own.
/// - An unedited plugin skill's settings move to each activation that used
///   it (secret ones into the Keychain under the projected skill's ID), the
///   templates and schedules that named it are pointed at the projected ID,
///   and the row is deleted. An edited one stays as an authored skill and the
///   activation skips its component. Tools follow the same rule.
/// - A row whose plugin is no longer in the library, that no activation
///   uses, or that a workspace turned on by itself without the plugin, is
///   kept as an authored row rather than lost.
/// - Deleted rows' secret namespaces go through `PluginSecretCleanupOutbox`,
///   recorded before the save.
///
/// Every change is one save. A secret that cannot be copied aborts the whole
/// migration before the save, so nothing is deleted with its settings
/// stranded; the next launch tries again.
@MainActor
enum PluginActivationMigration {
    struct Report: Equatable {
        var activations = 0
        var accountsBound = 0
        var skillsProjected = 0
        var skillsKeptAsAuthored = 0
        var toolsProjected = 0
        var toolsKeptAsAuthored = 0
    }

    enum MigrationError: Error, Equatable {
        case secretCopyFailed(skill: String, key: String)
        case cleanupUnrecordable
    }

    /// Runs the migration against the app's store when it has legacy state.
    static func migrateIfNeeded(modelContext context: ModelContext) {
        guard needsMigration(modelContext: context) else { return }
        do {
            let report = try migrate(
                modelContext: context,
                packages: CapabilityRuntimeResourceMatcher.packageDefinitions()
            )
            AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
                "migration": "plugin_activations_v20",
                "result": "migrated",
                "activations": String(report.activations),
                "accounts_bound": String(report.accountsBound),
                "skills_projected": String(report.skillsProjected),
                "skills_kept_authored": String(report.skillsKeptAsAuthored),
                "tools_projected": String(report.toolsProjected),
                "tools_kept_authored": String(report.toolsKeptAsAuthored)
            ])
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "migration": "plugin_activations_v20",
                "result": "deferred",
                "error_type": String(describing: error)
            ], level: .error)
        }
    }

    static func needsMigration(modelContext: ModelContext) -> Bool {
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        if workspaces.contains(where: { !$0.legacyEnabledCapabilityIDs.isEmpty || !$0.legacyInstalledPluginIDs.isEmpty }) {
            return true
        }
        let skills = (try? modelContext.fetch(FetchDescriptor<Skill>())) ?? []
        if skills.contains(where: isPluginOrigin) { return true }
        let tools = (try? modelContext.fetch(FetchDescriptor<LocalTool>())) ?? []
        return tools.contains(where: isPluginOrigin)
    }

    @discardableResult
    static func migrate(modelContext: ModelContext, packages: [PluginPackage]) throws -> Report {
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        let connectors = try modelContext.fetch(FetchDescriptor<Connector>())
        let skills = try modelContext.fetch(FetchDescriptor<Skill>())
        let tools = try modelContext.fetch(FetchDescriptor<LocalTool>())
        var report = Report()
        var releasedSkillIDs: [UUID] = []

        do {
            for workspace in workspaces {
                report.activations += migrateEnablement(of: workspace, packagesByID: packagesByID)
            }
            var activationsByPlugin: [String: [(Workspace, PluginActivation)]] = [:]
            for workspace in workspaces {
                for activation in WorkspaceCapabilityActivation.activations(of: workspace) {
                    activationsByPlugin[activation.pluginID, default: []].append((workspace, activation))
                }
            }
            func targets(pluginID: String, owner: Workspace?) -> [(Workspace, PluginActivation)] {
                let all = activationsByPlugin[pluginID] ?? []
                guard let owner else { return all }
                return all.filter { $0.0.id == owner.id }
            }

            // V19 stored no default account: binding in creation order makes
            // each component's oldest account its default.
            for connector in connectors.sorted(by: { $0.createdAt < $1.createdAt }) where isPluginOrigin(connector) {
                let pluginID = trimmed(connector.originPackageID)
                let componentID = connectorComponentID(connector, package: packagesByID[pluginID])
                let bindTo = targets(pluginID: pluginID, owner: connector.isGlobal ? nil : connector.workspace)
                guard !bindTo.isEmpty else { continue }
                KeychainService.synchronizeConnectorCredentialNamespaces(connector: connector)
                connector.skill = nil
                for (workspace, activation) in bindTo
                where !activation.bindings.contains(where: { $0.account?.id == connector.id }) {
                    WorkspaceCapabilityActivation.bind(connector, toComponent: componentID, of: activation)
                    let id = connector.id.uuidString
                    if workspace.enabledGlobalConnectorIDs.contains(id) {
                        WorkspaceCapabilityActivation.mutate(workspace) { $0.globalConnectorIDs.removeAll { $0 == id } }
                    }
                    report.accountsBound += 1
                }
            }
            for workspace in workspaces {
                for activation in WorkspaceCapabilityActivation.activations(of: workspace) {
                    disambiguateAliases(in: activation)
                }
            }

            for skill in skills where isPluginOrigin(skill) && !skill.isSystemBuiltIn {
                let pluginID = trimmed(skill.originPackageID)
                let package = packagesByID[pluginID]
                let spec = package?.skills.first { matches($0, skill: skill) }
                let using = targets(pluginID: pluginID, owner: skill.isGlobal ? nil : skill.workspace)
                guard let package, let spec, !using.isEmpty else {
                    clearOrigin(skill)
                    report.skillsKeptAsAuthored += 1
                    continue
                }
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                if isEdited(skill, spec: spec, package: package) {
                    clearOrigin(skill)
                    for (workspace, activation) in using {
                        WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: skill.id, on: activation)
                        if skill.isGlobal, activation.isEnabled {
                            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalSkill(skill.id.uuidString) }
                        }
                    }
                    report.skillsKeptAsAuthored += 1
                    continue
                }
                for (workspace, activation) in using {
                    let projectedID = PluginRuntimeProjection.derivedID(activationID: activation.id, componentID: componentID)
                    try moveSettings(of: skill, spec: spec, componentID: componentID, to: activation, projectedID: projectedID)
                    retarget(skillID: skill.id, to: projectedID, in: workspace)
                }
                let skillID = skill.id.uuidString
                let usingIDs = Set(using.map(\.0.id))
                for workspace in workspaces
                where workspace.enabledGlobalSkillIDs.contains(skillID) && usingIDs.contains(workspace.id) {
                    WorkspaceCapabilityActivation.mutate(workspace) { $0.globalSkillIDs.removeAll { $0 == skillID } }
                }
                // A workspace that turned this one shared row on without its
                // plugin keeps it, as an authored row it alone still lists.
                if workspaces.contains(where: { !usingIDs.contains($0.id) && $0.enabledGlobalSkillIDs.contains(skillID) }) {
                    clearOrigin(skill)
                    report.skillsKeptAsAuthored += 1
                    continue
                }
                releasedSkillIDs.append(skill.id)
                for connector in skill.connectors { connector.skill = nil }
                for tool in skill.localTools { tool.skill = nil }
                modelContext.delete(skill)
                report.skillsProjected += 1
            }

            for tool in tools where isPluginOrigin(tool) {
                let pluginID = trimmed(tool.originPackageID)
                let package = packagesByID[pluginID]
                let spec = package?.localTools.first { matches($0, tool: tool) }
                let using = targets(pluginID: pluginID, owner: tool.isGlobal ? nil : tool.workspace)
                guard package != nil, let spec, !using.isEmpty else {
                    clearOrigin(tool)
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                if isEdited(tool, spec: spec) {
                    clearOrigin(tool)
                    tool.skill = nil
                    for (workspace, activation) in using {
                        WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: tool.id, on: activation)
                        if tool.isGlobal, activation.isEnabled {
                            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalTool(tool.id.uuidString) }
                        }
                    }
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                let toolID = tool.id.uuidString
                let usingIDs = Set(using.map(\.0.id))
                for workspace in workspaces
                where workspace.enabledGlobalToolIDs.contains(toolID) && usingIDs.contains(workspace.id) {
                    WorkspaceCapabilityActivation.mutate(workspace) { $0.globalToolIDs.removeAll { $0 == toolID } }
                }
                if workspaces.contains(where: { !usingIDs.contains($0.id) && $0.enabledGlobalToolIDs.contains(toolID) }) {
                    clearOrigin(tool)
                    tool.skill = nil
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                modelContext.delete(tool)
                report.toolsProjected += 1
            }

            // The deleted rows' secret namespaces are recorded before the
            // save: once it lands, nothing in the store names them.
            var saveError: Error?
            let saved = PluginSecretCleanupOutbox.deleteThenClean(releasedSkillIDs, modelContext: modelContext) {
                do {
                    try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: nil, modelContext: modelContext)
                    return true
                } catch {
                    saveError = error
                    return false
                }
            }
            guard saved else { throw saveError ?? MigrationError.cleanupUnrecordable }
        } catch {
            modelContext.rollback()
            throw error
        }
        return report
    }

    // MARK: - Steps

    private static func migrateEnablement(of workspace: Workspace, packagesByID: [String: PluginPackage]) -> Int {
        let installed = workspace.legacyInstalledPluginIDs
        let versions = workspace.legacyInstalledPluginVersions
        let enabled = workspace.legacyEnabledCapabilityIDs
        guard !installed.isEmpty || !enabled.isEmpty else { return 0 }
        let before = WorkspaceCapabilityActivation.activations(of: workspace).count
        WorkspaceCapabilityActivation.mutate(workspace) { state in
            for (index, id) in installed.enumerated() where !state.pluginIDs.contains(id) {
                state.recordInstalledPlugin(id: id, version: index < versions.count ? versions[index] : "")
            }
            for id in enabled {
                state.enableCapability(id)
            }
        }
        for id in Set(installed + enabled) {
            guard let package = packagesByID[id],
                  let activation = WorkspaceCapabilityActivation.activation(for: id, in: workspace),
                  activation.recordedDigest.isEmpty else { continue }
            WorkspaceCapabilityActivation.recordAccepted(
                pluginID: id,
                version: activation.recordedVersion.isEmpty ? package.version : activation.recordedVersion,
                digest: (try? CapabilityApprovalDigest.digest(for: package)) ?? "",
                in: workspace
            )
        }
        workspace.legacyEnabledCapabilityIDs = []
        workspace.legacyInstalledPluginIDs = []
        workspace.legacyInstalledPluginVersions = []
        return WorkspaceCapabilityActivation.activations(of: workspace).count - before
    }

    /// Settings that differ from the plugin's defaults move to the
    /// activation; secret ones are copied into the projected skill's Keychain
    /// namespace.
    private static func moveSettings(
        of skill: Skill,
        spec: PluginSkill,
        componentID: String,
        to activation: PluginActivation,
        projectedID: UUID
    ) throws {
        let persistence = SkillSecretSeam.required
        for (index, key) in skill.environmentKeys.enumerated() {
            if Skill.isSecretEnvironmentKey(key) {
                let stored = persistence.loadSecretValue(key: key, skillID: skill.id, store: KeychainSecretStore())
                let legacy = index < skill.environmentValues.count ? skill.environmentValues[index] : ""
                let value = stored ?? legacy
                guard !value.isEmpty else { continue }
                guard persistence.saveSecretValue(
                    value,
                    key: key,
                    skillID: projectedID,
                    skillName: skill.name,
                    allowUserInteraction: false
                ) else {
                    throw MigrationError.secretCopyFailed(skill: skill.name, key: key)
                }
                continue
            }
            let value = index < skill.environmentValues.count ? skill.environmentValues[index] : ""
            let specIndex = spec.environmentKeys.firstIndex(of: key)
            let defaultValue = specIndex.flatMap { $0 < spec.environmentValues.count ? spec.environmentValues[$0] : nil } ?? ""
            guard !value.isEmpty, value != defaultValue else { continue }
            WorkspaceCapabilityActivation.setConfigValue(value, forKey: "\(componentID).\(key)", on: activation)
        }
    }

    /// Templates and schedules that named the skill row name its projection.
    private static func retarget(skillID: UUID, to projectedID: UUID, in workspace: Workspace) {
        let old = skillID.uuidString
        let new = projectedID.uuidString
        for template in workspace.templates where template.defaultSkillIDs.contains(old) {
            template.defaultSkillIDs = template.defaultSkillIDs.map { $0 == old ? new : $0 }
        }
        for schedule in workspace.schedules where schedule.skillIDs.contains(old) {
            schedule.skillIDs = schedule.skillIDs.map { $0 == old ? new : $0 }
        }
    }

    /// Accounts bound to one component share a service, so their names must
    /// tell them apart: a repeated name gets " 2", " 3" in creation order.
    private static func disambiguateAliases(in activation: PluginActivation) {
        let byComponent = Dictionary(grouping: activation.bindings.filter { !$0.isDeleted }, by: \.componentID)
        for bindings in byComponent.values where bindings.count > 1 {
            var seen: [String: Int] = [:]
            let accounts = bindings.compactMap(\.account).sorted { $0.createdAt < $1.createdAt }
            for account in accounts {
                let key = account.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let count = (seen[key] ?? 0) + 1
                seen[key] = count
                if count > 1 {
                    account.name = "\(account.name) \(count)"
                    account.updatedAt = Date()
                }
            }
        }
    }

    // MARK: - Matching

    private static func isPluginOrigin(_ skill: Skill) -> Bool { !trimmed(skill.originPackageID).isEmpty }
    private static func isPluginOrigin(_ connector: Connector) -> Bool { !trimmed(connector.originPackageID).isEmpty }
    private static func isPluginOrigin(_ tool: LocalTool) -> Bool { !trimmed(tool.originPackageID).isEmpty }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func connectorComponentID(_ connector: Connector, package: PluginPackage?) -> String {
        let stamped = trimmed(connector.originComponentID)
        if !stamped.isEmpty { return stamped }
        if let spec = package?.connectors.first(where: {
            CapabilityRuntimeResourceMatcher.normalizedName($0.name) == CapabilityRuntimeResourceMatcher.normalizedName(connector.name)
        }) ?? package?.connectors.first(where: {
            CapabilityRuntimeResourceMatcher.normalizedServiceType($0.serviceType)
                == CapabilityRuntimeResourceMatcher.normalizedServiceType(connector.serviceType)
        }) {
            return CapabilityResourceOrigin.componentID(for: spec)
        }
        let service = CapabilityRuntimeResourceMatcher.normalizedServiceType(connector.serviceType)
        return "connector:\(service):\(CapabilityRuntimeResourceMatcher.normalizedName(connector.name))"
    }

    private static func matches(_ spec: PluginSkill, skill: Skill) -> Bool {
        let stamped = trimmed(skill.originComponentID)
        if !stamped.isEmpty { return stamped == CapabilityResourceOrigin.componentID(for: spec) }
        return CapabilityRuntimeResourceMatcher.skillMatches(spec, skill: skill)
    }

    private static func matches(_ spec: PluginLocalTool, tool: LocalTool) -> Bool {
        let stamped = trimmed(tool.originComponentID)
        if !stamped.isEmpty { return stamped == CapabilityResourceOrigin.componentID(for: spec) }
        return CapabilityRuntimeResourceMatcher.toolMatches(spec, tool: tool)
    }

    /// A row made from the plugin's current version that no longer matches
    /// it was edited by the person. A row from another version can't be told
    /// apart from the version's own changes, and the startup repair kept those
    /// rows in step with the library, so it is treated as unedited.
    private static func isEdited(_ skill: Skill, spec: PluginSkill, package: PluginPackage) -> Bool {
        guard trimmed(skill.originPackageVersion).isEmpty || skill.originPackageVersion == package.version else {
            return false
        }
        return skill.name != spec.name
            || skill.skillDescription != spec.description
            || skill.allowedTools != spec.allowedTools
            || skill.customTools != spec.customTools
            || !behaviorMatches(skill.behaviorInstructions, spec: spec)
    }

    /// The one-time startup migration folds `disallowedTools` into the
    /// behavior text, so a row may carry the spec's text plus that note.
    private static func behaviorMatches(_ behavior: String, spec: PluginSkill) -> Bool {
        if behavior == spec.behaviorInstructions { return true }
        guard !spec.disallowedTools.isEmpty else { return false }
        return behavior.hasPrefix(spec.behaviorInstructions)
            && spec.disallowedTools.allSatisfy { behavior.contains($0) }
    }

    private static func isEdited(_ tool: LocalTool, spec: PluginLocalTool) -> Bool {
        tool.name != spec.name
            || tool.toolType != spec.toolType
            || tool.command != spec.command
            || tool.arguments != spec.arguments
    }

    private static func clearOrigin(_ skill: Skill) {
        skill.originPackageID = nil
        skill.originPackageVersion = nil
        skill.originComponentID = nil
        skill.originComponentKind = nil
        skill.originSourceKind = nil
        skill.updatedAt = Date()
    }

    private static func clearOrigin(_ tool: LocalTool) {
        tool.originPackageID = nil
        tool.originPackageVersion = nil
        tool.originComponentID = nil
        tool.originComponentKind = nil
        tool.originSourceKind = nil
        tool.updatedAt = Date()
    }
}
