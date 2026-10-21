import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Moves a V19/V20 store's plugin state onto `PluginActivation` (Plugins 2.0 R1).
///
/// Runs once the V21 store is open, before anything resolves capabilities,
/// and again on any later launch that still finds legacy state, so an
/// interrupted run finishes. It is idempotent: a store with no legacy
/// enablement arrays and no pending plugin-origin rows is left alone.
///
/// - Each workspace gets one activation per plugin in its legacy installed or
///   enabled lists, on when it was enabled, accepting the definition it
///   migrates against (its version and `PluginDefinitionDigest`).
/// - A plugin-origin connector stays a row and becomes an account: a
///   workspace-owned one is bound to its workspace's activation, a shared one
///   to every activation of its plugin. Credentials stored only under the
///   stable namespace are copied into the row's own.
/// - An unedited plugin skill's settings move to each activation that used
///   it (secret ones into a private activation generation), the
///   templates and schedules that named it are pointed at the projected ID,
///   and the row is deleted. An edited one stays as an authored skill the
///   activation names as its component's override, on only while the
///   activation is. Tools follow the same rule.
/// - A row whose plugin is no longer in the library, that no activation
///   uses, or that a workspace turned on by itself without the plugin, is
///   kept as an authored row rather than lost; so is an account whose plugin
///   is no longer in the library. A row of a missing plugin an activation
///   uses is recorded as pending as that activation's override of the
///   component it came from: once the definition is back (Add, or this pass
///   on a later launch) it replaces that component instead of sitting next
///   to the plugin's own copy.
/// - Deleted rows' secret namespaces go through `PluginSecretCleanupOutbox`,
///   recorded before the save.
///
/// Every change shares a durable operation receipt. Secret copies are private
/// until publication; only proved noncommit permits rollback. Saved or uncertain
/// outcomes retain their namespace and mirror recovery instead of undoing them.
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
        case secretReadFailed(skill: String, key: String)
        case cleanupUnrecordable, pendingEdits, saveFailed
    }

    /// The definitions this build ships, plus the library's own plugins.
    /// A built-in's copy on disk may be a previous version the catalog sync
    /// (after launch) hasn't replaced yet: migrating against it would record
    /// an obsolete component graph, so the bundled one wins, and a built-in
    /// this build no longer ships is not migrated as a plugin.
    static func currentDefinitions() -> [PluginPackage] {
        let builtIns = PluginCatalog.builtInPackages
        let builtInIDs = Set(builtIns.map(\.id))
        let library = CapabilityRuntimeResourceMatcher.packageDefinitions().filter { package in
            !builtInIDs.contains(package.id)
                && !CapabilityLibrary.trustedBuiltInPackageIDs.contains(package.id)
                && package.sourceMetadata?.kind != "built-in"
        }
        return builtIns + library
    }

    /// Runs the migration against the app's store when it has legacy state.
    static func migrateIfNeeded(modelContext context: ModelContext) {
        let packages = currentDefinitions()
        guard needsMigration(modelContext: context, packages: packages) else { return }
        do {
            let report = try migrate(modelContext: context, packages: packages)
            AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
                "migration": "plugin_activations_v21",
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
                "migration": "plugin_activations_v21",
                "result": "deferred",
                "error_type": String(describing: error)
            ], level: .error)
        }
    }

    /// Legacy state to move, or an activation (one a mirror without history
    /// restored) whose known components were never seeded.
    static func needsMigration(modelContext: ModelContext, packages: [PluginPackage]? = nil) -> Bool {
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        if workspaces.contains(where: { !$0.legacyEnabledCapabilityIDs.isEmpty || !$0.legacyInstalledPluginIDs.isEmpty }) {
            return true
        }
        let definitions = packages ?? currentDefinitions()
        let withComponents = Set(definitions
            .filter { !PluginRuntimeProjection.componentIDs(of: $0).isEmpty }
            .map(\.id))
        let activations = (try? modelContext.fetch(FetchDescriptor<PluginActivation>())) ?? []
        if activations.contains(where: { $0.knownComponentIDs.isEmpty && withComponents.contains($0.pluginID) }) {
            return true
        }
        // Rows kept while a plugin was missing, and its definition is back.
        if workspaces.contains(where: { workspace in
            WorkspaceCapabilityActivation.pendingOverridePluginIDs(of: workspace).contains { pluginID in
                withComponents.contains(pluginID) && WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace) != nil
            }
        }) {
            return true
        }
        let skills = (try? modelContext.fetch(FetchDescriptor<Skill>())) ?? []
        if skills.contains(where: isPluginOrigin) { return true }
        let tools = (try? modelContext.fetch(FetchDescriptor<LocalTool>())) ?? []
        if tools.contains(where: isPluginOrigin) { return true }
        let connectors = (try? modelContext.fetch(FetchDescriptor<Connector>())) ?? []
        let definitionIDs = Set(definitions.map(\.id))
        return connectors.contains { account in
            isPluginOrigin(account) && (
                account.accountBindings.filter { !$0.isDeleted }.isEmpty
                || !definitionIDs.contains(trimmed(account.originPackageID))
                || (account.credentialNamespaceID == nil && !account.credentialKeys.isEmpty)
            )
        }
    }

    @discardableResult
    static func migrate(
        modelContext: ModelContext,
        packages: [PluginPackage],
        secrets: any SkillSecretPersisting.Type = SkillSecretSeam.required,
        persist: ((ModelContext) throws -> Void)? = nil,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws -> Report {
        guard !modelContext.hasChanges else { throw MigrationError.pendingEdits }
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        let connectors = try modelContext.fetch(FetchDescriptor<Connector>())
        let skills = try modelContext.fetch(FetchDescriptor<Skill>())
        let tools = try modelContext.fetch(FetchDescriptor<LocalTool>())
        // These rows may be removed, then restored by rollback. Even an
        // empty inverse must be materialized before any graph mutation.
        for workspace in workspaces { SwiftDataPluginRelationshipPreparation.prepare(workspace) }
        for skill in skills { SwiftDataDeletionPreparation.prepare(skill) }
        for tool in tools { SwiftDataDeletionPreparation.prepare(tool) }
        var report = Report()
        var releasedSkillIDs: [UUID] = []
        let credentials = PluginMigrationSkillCredentials(modelContext: modelContext, persistence: secrets)
        let accountCredentials = PluginMigrationAccountCredentials(modelContext: modelContext)
        // rollback() doesn't restore array-backed state (legacy and global
        // memberships, activation records): a failed run puts it back.
        let restoreState = PluginUpdateService.captureState(of: workspaces)

        do {
            for workspace in workspaces {
                report.activations += migrateEnablement(of: workspace, packagesByID: packagesByID)
            }
            // The definition each activation starts from, so a later Update
            // can tell which components it dropped.
            for workspace in workspaces {
                for activation in WorkspaceCapabilityActivation.activations(of: workspace)
                where activation.knownComponentIDs.isEmpty {
                    guard let package = packagesByID[activation.pluginID] else { continue }
                    WorkspaceCapabilityActivation.setKnownComponents(
                        PluginRuntimeProjection.componentIDs(of: package),
                        on: activation
                    )
                }
                // Rows kept while the plugin was missing replace the
                // components they came from now that it is back.
                for activation in WorkspaceCapabilityActivation.activations(of: workspace) {
                    guard let package = packagesByID[activation.pluginID] else { continue }
                    WorkspaceCapabilityActivation.adoptPendingOverrides(
                        on: activation, declaring: PluginRuntimeProjection.componentIDs(of: package), in: workspace
                    )
                }
            }
            // Template rows the plugin wrote and the person left as they
            // are, so a later Update can tell them from edited ones.
            for workspace in workspaces {
                for activation in WorkspaceCapabilityActivation.activations(of: workspace)
                where activation.templateDigests.isEmpty {
                    guard let package = packagesByID[activation.pluginID] else { continue }
                    PluginTemplateSync.recordUnedited(package, in: workspace, on: activation)
                }
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
            // A workspace that lists a shared plugin row with the plugin not
            // on there turned it on by itself: V19's Disable took a plugin's
            // rows off the lists, so one listed beside an off activation was
            // turned on again on its own. It keeps the row on, as its own.
            func usesOnItsOwn(_ workspace: Workspace, _ pluginID: String, _ list: KeyPath<WorkspaceCapabilityActivationState, [String]>, _ rowID: UUID) -> Bool {
                WorkspaceCapabilityActivation.state(of: workspace)[keyPath: list].contains(rowID.uuidString)
                    && WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace)?.isEnabled != true
            }
            // Shared plugin skills a workspace turned on without the plugin
            // are kept as authored rows there, with their tools and accounts.
            let independentSkillIDs = Set(skills.filter { skill in
                guard isPluginOrigin(skill), skill.isGlobal else { return false }
                return workspaces.contains { usesOnItsOwn($0, trimmed(skill.originPackageID), \.globalSkillIDs, skill.id) }
            }.map(\.id))
            // A workspace that gave a component its own account (scoped
            // inputs) stopped listing the shared one: it isn't bound there.
            func replacedShared(_ connector: Connector, componentID: String, in workspace: Workspace) -> Bool {
                guard connector.isGlobal,
                      !WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs.contains(connector.id.uuidString)
                else { return false }
                let pluginID = trimmed(connector.originPackageID)
                return connectors.contains { other in
                    !other.isGlobal && other.workspace?.id == workspace.id && trimmed(other.originPackageID) == pluginID
                        && connectorComponentID(other, package: packagesByID[pluginID]) == componentID
                }
            }

            // Original V20 selections take precedence; V19 falls back to the
            // oldest account when it has no recorded service default.
            for connector in connectors.sorted(by: { $0.createdAt < $1.createdAt }) where isPluginOrigin(connector) {
                let pluginID = trimmed(connector.originPackageID)
                try accountCredentials.prepare(connector)
                // Without its definition (a custom plugin's file missing or
                // unreadable) nothing could project a bound account back into
                // scope: it stays the person's, as authored, as skills do.
                guard packagesByID[pluginID] != nil else {
                    CapabilityResourceOrigin.releaseProvenance(of: connector)
                    continue
                }
                let componentID = connectorComponentID(connector, package: packagesByID[pluginID])
                let bindTo = targets(pluginID: pluginID, owner: connector.isGlobal ? nil : connector.workspace)
                    .filter { !replacedShared(connector, componentID: componentID, in: $0.0) }
                    // Listed there on its own, it stays the workspace's
                    // shared row: bound, the off activation would hide it.
                    .filter { !usesOnItsOwn($0.0, pluginID, \.globalConnectorIDs, connector.id) }
                guard !bindTo.isEmpty else {
                    CapabilityResourceOrigin.releaseProvenance(of: connector)
                    continue
                }
                // An account of a skill kept for a workspace without the
                // plugin stays that skill's; it is also an account of the
                // activations that bind it.
                if !(connector.skill.map { independentSkillIDs.contains($0.id) } ?? false) { connector.skill = nil }
                for (workspace, activation) in bindTo
                where !activation.bindings.contains(where: { $0.account?.id == connector.id }) {
                    PluginV20AccountChoices.bind(connector, componentID: componentID, to: activation, in: workspace)
                    let id = connector.id.uuidString
                    if workspace.enabledGlobalConnectorIDs.contains(id) {
                        WorkspaceCapabilityActivation.mutate(workspace) { $0.globalConnectorIDs.removeAll { $0 == id } }
                    }
                    report.accountsBound += 1
                }
            }

            for skill in skills where isPluginOrigin(skill) {
                let pluginID = trimmed(skill.originPackageID)
                let package = packagesByID[pluginID]
                let spec = package?.skills.first { matches($0, skill: skill) }
                let using = targets(pluginID: pluginID, owner: skill.isGlobal ? nil : skill.workspace)
                guard let package, let spec, !using.isEmpty else {
                    if package == nil { recordPending(skill.id, componentID: pendingComponentID(of: skill), for: using) }
                    clearOrigin(skill)
                    report.skillsKeptAsAuthored += 1
                    continue
                }
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                // A row the person attached their own connector or tool to
                // is theirs too: deleting it would leave those attachments
                // ownerless, in the workspace's ambient scope even with the
                // plugin off. Kept as the override, they stay with it.
                if isEdited(skill, spec: spec) || hasAuthoredAttachments(skill) {
                    clearOrigin(skill)
                    // The override is on exactly while its activation is
                    // (the projection brings the row in): a shared-list
                    // membership would keep it on after the plugin is off. A
                    // workspace's own row stays in its lists but out of its
                    // ambient inventory (`WorkspaceCapabilities`).
                    let skillID = skill.id.uuidString
                    for (workspace, activation) in using where !usesOnItsOwn(workspace, pluginID, \.globalSkillIDs, skill.id) {
                        WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: skill.id, on: activation)
                        WorkspaceCapabilityActivation.mutate(workspace) { $0.globalSkillIDs.removeAll { $0 == skillID } }
                    }
                    report.skillsKeptAsAuthored += 1
                    continue
                }
                for (workspace, activation) in using {
                    let projectedID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
                    try credentials.copy(from: skill, to: activation, in: workspace,
                        package: package, componentID: componentID)
                    moveNonSecretSettings(of: skill, spec: spec, componentID: componentID, to: activation)
                    // Where the row stays on by itself, what names it keeps it.
                    if !usesOnItsOwn(workspace, pluginID, \.globalSkillIDs, skill.id) {
                        retarget(skillID: skill.id, to: projectedID, in: workspace)
                    }
                }
                let skillID = skill.id.uuidString
                for (workspace, _) in using
                where workspace.enabledGlobalSkillIDs.contains(skillID) && !usesOnItsOwn(workspace, pluginID, \.globalSkillIDs, skill.id) {
                    WorkspaceCapabilityActivation.mutate(workspace) { $0.globalSkillIDs.removeAll { $0 == skillID } }
                }
                // A workspace that turned this one shared row on without its
                // plugin keeps it, as an authored row it alone still lists.
                if independentSkillIDs.contains(skill.id) {
                    clearOrigin(skill)
                    report.skillsKeptAsAuthored += 1
                    continue
                }
                releasedSkillIDs.append(skill.secretNamespaceID)
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
                    if package == nil { recordPending(tool.id, componentID: pendingComponentID(of: tool), for: using) }
                    clearOrigin(tool)
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                let componentID = CapabilityResourceOrigin.componentID(for: spec)
                // A tool of a skill kept for a workspace without the plugin
                // stays that skill's, as an authored row. Edited, it is also
                // what the workspaces with the plugin used: there it replaces
                // the plugin's tool, as any edited tool does.
                let keptForIndependentSkill = tool.skill.map { independentSkillIDs.contains($0.id) } ?? false
                if keptForIndependentSkill, !isEdited(tool, spec: spec) {
                    clearOrigin(tool)
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                if isEdited(tool, spec: spec) {
                    clearOrigin(tool)
                    // Its skill row may be deleted above: the projection wires
                    // the runtime's copy to the plugin's first skill instead.
                    if !keptForIndependentSkill { tool.skill = nil }
                    let toolID = tool.id.uuidString
                    for (workspace, activation) in using where !usesOnItsOwn(workspace, pluginID, \.globalToolIDs, tool.id) {
                        WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: tool.id, on: activation)
                        WorkspaceCapabilityActivation.mutate(workspace) { $0.globalToolIDs.removeAll { $0 == toolID } }
                    }
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                let toolID = tool.id.uuidString
                for (workspace, _) in using
                where workspace.enabledGlobalToolIDs.contains(toolID) && !usesOnItsOwn(workspace, pluginID, \.globalToolIDs, tool.id) {
                    WorkspaceCapabilityActivation.mutate(workspace) { $0.globalToolIDs.removeAll { $0 == toolID } }
                }
                if workspaces.contains(where: { usesOnItsOwn($0, pluginID, \.globalToolIDs, tool.id) }) {
                    clearOrigin(tool)
                    tool.skill = nil
                    report.toolsKeptAsAuthored += 1
                    continue
                }
                modelContext.delete(tool)
                report.toolsProjected += 1
            }

            releasedSkillIDs += credentials.released
            guard report != Report() || modelContext.hasChanges || !releasedSkillIDs.isEmpty else { return report }
            var saveError: Error?
            var committed: PluginOperationCommit.Outcome?
            var recoveryComplete = false
            let saved = PluginSecretCleanupOutbox.deleteThenClean(releasedSkillIDs, modelContext: modelContext,
                secrets: secrets, producerLease: credentials.producerLease, save: {
                    let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: packages.map(\.id),
                        workspaceIDs: workspaces.map(\.id), modelContext: modelContext,
                        persist: persist ?? { context in
                            guard WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context) else {
                                throw MigrationError.saveFailed
                            }
                        })
                    committed = outcome
                    if case .notCommitted(let error) = outcome { saveError = error; return false }
                    return true
                }, beforeSettling: {
                    guard case .committed(let receipt, let reportedFailure) = committed, !reportedFailure else { return false }
                    let export: ((Workspace, ModelContext) -> Bool)? = rewriteMirror.map { write in { workspace, _ in write(workspace) } }
                    recoveryComplete = PluginOperationRecovery.resumePending(modelContext: modelContext,
                        only: receipt.id, export: export).completed == 1
                    return recoveryComplete
                })
            guard saved else { throw saveError ?? MigrationError.cleanupUnrecordable }
            if case .indeterminate(let id, _) = committed { throw PluginOperationProblem.commitUncertain(id) }
            if !recoveryComplete, case .committed(let receipt, _) = committed {
                throw PluginOperationProblem.savedRecoveryPending(receipt.id)
            }
            credentials.completed(in: workspaces)
            accountCredentials.completed()
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            modelContext.rollback()
            restoreState()
            credentials.discard()
            accountCredentials.discard()
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
            // The rows move onto this definition's components, so the
            // activation accepts it: one recording the legacy version would
            // stop running until an Update accepted what it already holds.
            WorkspaceCapabilityActivation.recordAccepted(
                pluginID: id,
                version: package.version,
                digest: PluginDefinitionDigest.content(of: package),
                in: workspace
            )
        }
        workspace.legacyEnabledCapabilityIDs = []
        workspace.legacyInstalledPluginIDs = []
        workspace.legacyInstalledPluginVersions = []
        return WorkspaceCapabilityActivation.activations(of: workspace).count - before
    }

    /// Settings that differ from the plugin's defaults move to the
    /// activation, an emptied one included (the person cleared a default);
    /// Credential copies are handled by the private-generation participant.
    private static func moveNonSecretSettings(of skill: Skill, spec: PluginSkill,
                                              componentID: String, to activation: PluginActivation) {
        for (index, key) in skill.environmentKeys.enumerated() where !Skill.isSecretEnvironmentKey(key) {
            let value = index < skill.environmentValues.count ? skill.environmentValues[index] : ""
            let specIndex = spec.environmentKeys.firstIndex(of: key)
            let defaultValue = specIndex.flatMap { $0 < spec.environmentValues.count ? spec.environmentValues[$0] : nil } ?? ""
            guard value != defaultValue else { continue }
            WorkspaceCapabilityActivation.setConfigValue(value,
                forKey: PluginActivation.settingKey(componentID: componentID, key: key), on: activation)
        }
    }

    /// Templates and schedules that named the skill row name its projection.
    private static func retarget(skillID: UUID, to projectedID: UUID, in workspace: Workspace) {
        let old = skillID.uuidString
        let new = projectedID.uuidString
        for template in workspace.templates where template.defaultSkillIDs.contains(old) {
            WorkspaceCapabilityActivation.rewriteDefaultSkills(of: template, in: workspace) { $0.map { $0 == old ? new : $0 } }
        }
        for schedule in workspace.schedules where schedule.skillIDs.contains(old) {
            schedule.skillIDs = schedule.skillIDs.map { $0 == old ? new : $0 }
        }
    }

    /// A row of a missing plugin, kept as authored, is pending as each using
    /// activation's override of `componentID` (`adoptPendingOverrides`).
    private static func recordPending(_ rowID: UUID, componentID: String, for using: [(Workspace, PluginActivation)]) {
        for (workspace, activation) in using {
            WorkspaceCapabilityActivation.recordPendingOverride(
                componentID: componentID, rowID: rowID, pluginID: activation.pluginID, in: workspace
            )
        }
    }

    /// The component a row came from: its stamp, else the ID a definition
    /// declaring a component like it would give (what `matches` compares).
    private static func pendingComponentID(of skill: Skill) -> String {
        let stamped = trimmed(skill.originComponentID)
        guard stamped.isEmpty else { return stamped }
        return CapabilityResourceOrigin.componentID(for: PluginSkill(
            name: skill.name, icon: "", description: "", allowedTools: [], disallowedTools: [], customTools: [],
            behaviorInstructions: "", environmentKeys: [], environmentValues: []
        ))
    }

    private static func pendingComponentID(of tool: LocalTool) -> String {
        let stamped = trimmed(tool.originComponentID)
        guard stamped.isEmpty else { return stamped }
        return CapabilityResourceOrigin.componentID(for: PluginLocalTool(
            name: tool.name, description: "", icon: "", toolType: tool.toolType, command: tool.command, arguments: tool.arguments
        ))
    }

    // MARK: - Matching

    private static func isPluginOrigin(_ skill: Skill) -> Bool { !trimmed(skill.originPackageID).isEmpty }
    private static func isPluginOrigin(_ connector: Connector) -> Bool { !trimmed(connector.originPackageID).isEmpty }
    private static func isPluginOrigin(_ tool: LocalTool) -> Bool { !trimmed(tool.originPackageID).isEmpty }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A stamp naming an identity the definition `replaces` (a name-derived
    /// one a stable ID took over) resolves to the component that replaced
    /// it, as skill and tool stamps do: the activation is seeded from the
    /// current definition, so a binding under the old identity is never
    /// reconciled and the account would serve nothing.
    private static func connectorComponentID(_ connector: Connector, package: PluginPackage?) -> String {
        let stamped = trimmed(connector.originComponentID)
        if !stamped.isEmpty {
            let successor = package?.connectors.first {
                CapabilityResourceOrigin.replacedComponentIDs(for: $0).contains(stamped)
            }
            guard let successor,
                  package?.connectors.contains(where: { CapabilityResourceOrigin.componentID(for: $0) == stamped }) != true
            else { return stamped }
            return CapabilityResourceOrigin.componentID(for: successor)
        }
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

    /// A stamped row is the component its stamp names: the spec's own ID,
    /// or one the spec `replaces` (an earlier build stamped the identity a
    /// later definition renamed, such as a name-derived one a stable ID took
    /// over), so its settings and secrets move instead of a second component
    /// being projected beside it.
    private static func matches(_ spec: PluginSkill, skill: Skill) -> Bool {
        let stamped = trimmed(skill.originComponentID)
        if !stamped.isEmpty {
            return stamped == CapabilityResourceOrigin.componentID(for: spec)
                || CapabilityResourceOrigin.replacedComponentIDs(for: spec).contains(stamped)
        }
        return CapabilityRuntimeResourceMatcher.skillMatches(spec, skill: skill)
    }

    private static func matches(_ spec: PluginLocalTool, tool: LocalTool) -> Bool {
        let stamped = trimmed(tool.originComponentID)
        if !stamped.isEmpty {
            return stamped == CapabilityResourceOrigin.componentID(for: spec)
                || CapabilityResourceOrigin.replacedComponentIDs(for: spec).contains(stamped)
        }
        return CapabilityRuntimeResourceMatcher.toolMatches(spec, tool: tool)
    }

    /// A row that no longer matches the plugin's current definition was
    /// edited by the person. A row stamped with another version is compared
    /// the same way: the person may have edited it after the last startup
    /// repair, and the version's own changes can't be told apart from theirs.
    /// Keeping it as an override is recoverable; deleting it is not.
    private static func isEdited(_ skill: Skill, spec: PluginSkill) -> Bool {
        skill.name != spec.name
            || Set(skill.environmentKeys) != Set(spec.environmentKeys)
            || skill.icon != spec.icon
            || skill.skillDescription != spec.description
            || skill.allowedTools != spec.allowedTools
            || skill.customTools != spec.customTools
            || !restrictionsMatch(skill, spec: spec)
    }

    /// A row's denied tools and behavior text say what the spec's do. The
    /// startup pass folds `disallowedTools` into the behavior text, and this
    /// migration runs before it, so a row is either as installed (the spec's
    /// list and text) or folded: no list, and the spec's text plus exactly
    /// the note it appends (`migrateDisallowedToolsToBehavior`). Anything
    /// else, a denial added or removed included, is the person's.
    private static func restrictionsMatch(_ skill: Skill, spec: PluginSkill) -> Bool {
        if skill.disallowedTools == spec.disallowedTools, skill.behaviorInstructions == spec.behaviorInstructions {
            return true
        }
        guard skill.disallowedTools.isEmpty, !spec.disallowedTools.isEmpty else { return false }
        let note = "\nDo NOT use these tools: \(spec.disallowedTools.joined(separator: ", "))."
        return skill.behaviorInstructions == spec.behaviorInstructions + note
    }

    private static func hasAuthoredAttachments(_ skill: Skill) -> Bool {
        skill.connectors.contains { !$0.isDeleted && !isPluginOrigin($0) }
            || skill.localTools.contains { !$0.isDeleted && !isPluginOrigin($0) }
    }

    private static func isEdited(_ tool: LocalTool, spec: PluginLocalTool) -> Bool {
        tool.name != spec.name
            || tool.toolDescription != spec.description
            || tool.icon != spec.icon
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
