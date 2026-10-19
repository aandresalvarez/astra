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
    /// The projected accounts a binding marks as their service's default in
    /// this workspace (`AccountBinding.isDefault`, set by Make default), or,
    /// for a service whose default isn't projected, its oldest projected
    /// account (`projectedDefaults`). The broker resolves a call that names
    /// no account to the one default of its service; this is the only place
    /// that flag leaves the bindings.
    var defaultAccountIDs: Set<UUID> = []

    static let empty = PluginRuntimeProjection(skills: [], tools: [], connectors: [], unboundConnectorComponents: [:])

    /// Projects every enabled activation of `workspace` whose plugin is in
    /// `packages` (the caller's enabled, policy-allowed definitions), except
    /// one that awaits Update (`awaitsUpdate`). `definitions` are the
    /// installed definitions a shared account's creator is looked up in when
    /// that plugin is not among `packages` (off here, or not runnable); nil
    /// reads the library, only when such an account is bound.
    static func project(
        workspace: Workspace?,
        packages: [PluginPackage],
        connectorMode: ConnectorMode = .accounts,
        definitions: [PluginPackage]? = nil
    ) -> PluginRuntimeProjection {
        guard let workspace, !packages.isEmpty else { return .empty }
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var definitionsByID: [String: PluginPackage]?
        func creator(_ packageID: String) -> PluginPackage? {
            if let package = packagesByID[packageID] { return package }
            if definitionsByID == nil {
                definitionsByID = Dictionary(
                    (definitions ?? CapabilityRuntimeResourceMatcher.packageDefinitions()).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            return definitionsByID?[packageID]
        }
        var skills: [Skill] = []
        var tools: [LocalTool] = []
        var connectors: [Connector] = []
        var unbound: [String: [String]] = [:]
        var seenConnectorIDs = Set<UUID>()
        // A runtime copy is filtered once every plugin that binds its
        // account is known: the copy serves any of them.
        var copies: [UUID: (account: Connector, copy: Connector)] = [:]
        var bindingOwners: [UUID: [(spec: PluginConnector, package: PluginPackage)]] = [:]
        var owners: [UUID: Set<UUID>] = [:]
        var projectedBindings: [AccountBinding] = []

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
                // An account whose sign-in method this definition withdrew
                // stays bound, but nothing runs with it until it reconnects.
                let accounts = activation.accounts(forComponent: componentID)
                    .filter { !$0.isDeleted && !Self.signsInWithWithdrawnMethod($0, spec: spec, package: package) }
                if accounts.isEmpty {
                    unbound[package.id, default: []].append(componentID)
                }
                if let primarySkill {
                    for account in accounts { owners[account.id, default: []].insert(primarySkill.id) }
                }
                projectedBindings += activation.bindings.filter { binding in
                    !binding.isDeleted && binding.componentID == componentID && binding.account.map { !$0.isDeleted } == true
                }
                for account in accounts {
                    if connectorMode == .runtimeCopies { bindingOwners[account.id, default: []].append((spec, package)) }
                    if seenConnectorIDs.insert(account.id).inserted {
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
                            copies[account.id] = (account, copy)
                            connectors.append(copy)
                        }
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
        for (id, entry) in copies {
            retainDeclaredKeys(of: entry.account, on: entry.copy, bindings: bindingOwners[id] ?? [], creator: creator)
        }
        return PluginRuntimeProjection(
            skills: skills,
            tools: tools,
            connectors: connectors,
            unboundConnectorComponents: unbound,
            accountOwnerSkillIDs: owners,
            defaultAccountIDs: projectedDefaults(projectedBindings)
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
            workspaceID: activation.workspace?.id ?? activation.id,
            pluginID: activation.pluginID,
            componentID: componentID,
            seed: activation.namespaceSeed
        )
    }

    /// The component IDs a definition declares: skills, connectors, tools.
    nonisolated static func componentIDs(of package: PluginPackage) -> [String] {
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
    /// An automatic pass that would have released something, or that met a
    /// definition awaiting its review or changed under the same version,
    /// held it back (`awaitingUpdate`); otherwise it differs in its version,
    /// its content under the same version (`PluginDefinitionDigest`, which
    /// leaves out where a copy came from, so two copies of one definition
    /// agree), or its components. A digest recorded before content digests,
    /// or none (a mirror written before V20 carries only the version), can't
    /// be compared, so only the version and components are; an activation
    /// with no recorded version either has nothing to compare. Its plugin
    /// doesn't run, here or in a queued launch, until Update reconciles it;
    /// the Plugins row offers Update meanwhile.
    static func awaitsUpdate(_ activation: PluginActivation, to package: PluginPackage) -> Bool {
        if activation.awaitingUpdate { return true }
        if !activation.recordedVersion.isEmpty, activation.recordedVersion != package.version { return true }
        if PluginDefinitionDigest.matches(activation.recordedDigest, package) == false { return true }
        return !activation.knownComponentIDs.isEmpty && Set(activation.knownComponentIDs) != Set(componentIDs(of: package))
    }

    /// Whether `account`, which `package` created for `spec`'s component,
    /// signs in with a method the definition no longer declares. Derived
    /// from the definition, never stored: the account stays bound, out of
    /// every run and not ready (`CapabilityPackageState` asks it to
    /// reconnect), until it signs in with the declared method.
    static func signsInWithWithdrawnMethod(_ account: Connector, spec: PluginConnector, package: PluginPackage) -> Bool {
        account.originPackageID == package.id && !spec.authMethod.isEmpty && spec.authMethod != account.authMethod
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

    /// Per service, the projected accounts a binding marks default. Turning
    /// a plugin off keeps its bindings, default included, so turning it on
    /// gives the default back; meanwhile a service whose default is on such
    /// a binding falls back to its oldest projected binding (by creation,
    /// then ID), so a call that names no account still has one to reach.
    private static func projectedDefaults(_ bindings: [AccountBinding]) -> Set<UUID> {
        let byService = Dictionary(grouping: bindings) {
            ($0.account?.serviceType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var defaults = Set<UUID>()
        for group in byService.values {
            let stored = group.filter(\.isDefault).compactMap { $0.account?.id }
            if !stored.isEmpty {
                defaults.formUnion(stored)
            } else if let oldest = group.min(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })?.account {
                defaults.insert(oldest.id)
            }
        }
        return defaults
    }

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

    /// An account a plugin created carries the credentials and settings its
    /// creator's installed definition declares, whether or not that plugin
    /// is on here. A key an update stopped declaring stays on the row
    /// (Update keeps what the person entered) but never reaches a run. A
    /// creator whose definition can't be found (unreadable, or removed while
    /// its provenance stayed) fails closed: no credential reaches the run,
    /// and only the settings every plugin that binds it declares do, since
    /// the one copy serves a run scoped to any of them. An account no
    /// plugin created keeps everything the person entered. A setting its
    /// creator stores as a credential (`PluginConnectorFieldTrust`) reaches
    /// the run from the Keychain; one an older row still holds as plain text
    /// is kept as a setting until Add moves it.
    private static func retainDeclaredKeys(
        of account: Connector,
        on copy: Connector,
        bindings: [(spec: PluginConnector, package: PluginPackage)],
        creator: (String) -> PluginPackage?
    ) {
        guard let originID = account.originPackageID, !originID.isEmpty, let first = bindings.first else { return }
        var found: (spec: PluginConnector, package: PluginPackage)?
        for binding in bindings where found == nil {
            found = creatorDeclaration(of: account, originID: originID, binding: binding.spec, in: binding.package, creator: creator)
        }
        guard let declaration = found else {
            let shared = bindings.dropFirst().reduce(storedConfigKeys(of: first.spec, in: first.package, on: copy)) {
                $0.intersection(storedConfigKeys(of: $1.spec, in: $1.package, on: copy))
            }
            retain(credentials: [], config: shared, on: copy)
            return
        }
        retain(
            credentials: Set(PluginConnectorFieldTrust.asStored(declaration.spec, in: declaration.package).credentialHints.map(\.key)),
            config: storedConfigKeys(of: declaration.spec, in: declaration.package, on: copy),
            on: copy
        )
    }

    /// The connector declaration that created `account`: `binding` when the
    /// account is `package`'s, else its creator's component of the same ID,
    /// or the one that `replaces` it (a stamp an Update hasn't moved yet).
    private static func creatorDeclaration(
        of account: Connector,
        originID: String,
        binding spec: PluginConnector,
        in package: PluginPackage,
        creator: (String) -> PluginPackage?
    ) -> (spec: PluginConnector, package: PluginPackage)? {
        if originID == package.id { return (spec, package) }
        guard let creatorPackage = creator(originID), let stamp = account.originComponentID else { return nil }
        let connectors = creatorPackage.connectors
        let found = connectors.first { CapabilityResourceOrigin.componentID(for: $0) == stamp }
            ?? connectors.first { CapabilityResourceOrigin.replacedComponentIDs(for: $0).contains(stamp) }
        return found.map { ($0, creatorPackage) }
    }

    /// The setting keys an account of `spec` may carry plain into a run: the
    /// settings its stored projection keeps plain
    /// (`PluginConnectorFieldTrust.asStored`), its plugin's skill settings
    /// (`CapabilityInstaller`) and the ones a Stanford Outlook account always
    /// carries, less every key the plugin stores as a credential. A plain
    /// value an older row still holds for one of those (its move into the
    /// Keychain refused, or a different value already there) reaches no
    /// run as a setting: it is withheld until it is a credential.
    private static func storedConfigKeys(of spec: PluginConnector, in package: PluginPackage, on copy: Connector) -> Set<String> {
        let stored = PluginConnectorFieldTrust.asStored(spec, in: package)
        let promoted = PluginConnectorFieldTrust.settingsStoredAsCredentials(of: spec, in: package)
        var keys = Set(stored.configHints.map(\.key)).union(package.skills.flatMap(\.environmentKeys))
        if copy.isStanfordOutlookMail { keys.formUnion([StanfordOutlookMail.tenantDomainKey, StanfordOutlookMail.scopesKey]) }
        return keys.subtracting(promoted).subtracting(stored.credentialHints.map(\.key))
    }

    /// Drops from a runtime copy the credential and setting keys outside
    /// the declared sets, with their values. Credential keys compare
    /// canonically (`ConnectorCredentialKey`): a saved one is stored
    /// uppercased whatever the declaration's spelling.
    private static func retain(credentials: Set<String>, config: Set<String>, on copy: Connector) {
        let declared = Set(credentials.map(ConnectorCredentialKey.canonical))
        let keptCredentials = copy.credentialKeys.indices.filter { declared.contains(ConnectorCredentialKey.canonical(copy.credentialKeys[$0])) }
        if keptCredentials.count < copy.credentialKeys.count {
            copy.credentialValues = keptCredentials.map { $0 < copy.credentialValues.count ? copy.credentialValues[$0] : "" }
            copy.credentialKeys = keptCredentials.map { copy.credentialKeys[$0] }
        }
        let keptConfig = copy.configKeys.indices.filter { config.contains(copy.configKeys[$0]) }
        if keptConfig.count < copy.configKeys.count {
            copy.configValues = keptConfig.map { $0 < copy.configValues.count ? copy.configValues[$0] : "" }
            copy.configKeys = keptConfig.map { copy.configKeys[$0] }
        }
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
