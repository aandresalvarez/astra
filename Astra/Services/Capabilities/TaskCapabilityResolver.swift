import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskCapabilityResolutionScope: Equatable {
    case fullInventory
    case providerLaunch(contextText: String)

    var auditName: String {
        switch self {
        case .fullInventory:
            return "full_inventory"
        case .providerLaunch:
            return "provider_launch"
        }
    }

    var contextText: String {
        switch self {
        case .fullInventory:
            return ""
        case .providerLaunch(let contextText):
            return contextText
        }
    }

    var isProviderLaunch: Bool {
        if case .providerLaunch = self { return true }
        return false
    }
}

struct TaskCapabilityResolutionSnapshot {
    let fullInventory: TaskCapabilityPromptScope
    let providerLaunch: TaskCapabilityPromptScope
    let providerLaunchContextText: String
    let connectorCredentialExposurePolicy: ConnectorRuntimeProjection.CredentialExposurePolicy

    static func capture(
        for task: AgentTask,
        providerLaunchContextText: String,
        additionalCredentialGrants: [PermissionGrant] = [],
        turnIntentSnapshot: TaskTurnIntentSnapshot? = nil,
        runtime: AgentRuntimeID? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        // Kept temporarily as a source-compatible migration seam. Automatic
        // permission mode no longer broadens credential delivery.
        exposeAllConnectorCredentials _: Bool = false
    ) -> TaskCapabilityResolutionSnapshot {
        let activationText = turnIntentSnapshot?.activationText
            ?? providerLaunchContextText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolver = TaskCapabilityResolver(
            task: task,
            additionalCredentialGrants: additionalCredentialGrants,
            runtime: runtime,
            secretStore: secretStore
        )
        return TaskCapabilityResolutionSnapshot(
            fullInventory: resolver.resolvedScope(.fullInventory),
            providerLaunch: resolver.activationScope(contextText: activationText),
            providerLaunchContextText: activationText,
            connectorCredentialExposurePolicy: resolver.connectorCredentialExposurePolicy
        )
    }

    func scope(_ requestedScope: TaskCapabilityResolutionScope) -> TaskCapabilityPromptScope {
        switch requestedScope {
        case .fullInventory:
            return fullInventory
        case .providerLaunch:
            return providerLaunch
        }
    }
}

struct TaskCapabilityResolver {
    struct ResourceInventory {
        let behaviorSkills: [Skill]
        let connectors: [Connector]
        let localTools: [LocalTool]
    }

    private let task: AgentTask
    private let additionalCredentialGrants: [PermissionGrant]
    private let runtime: AgentRuntimeID?
    private let secretStore: SecretStore

    init(
        task: AgentTask,
        additionalCredentialGrants: [PermissionGrant] = [],
        runtime: AgentRuntimeID? = nil,
        secretStore: SecretStore = KeychainSecretStore()
    ) {
        self.task = task
        self.additionalCredentialGrants = additionalCredentialGrants
        self.runtime = runtime
        self.secretStore = secretStore
    }

    var resourceInventory: ResourceInventory {
        let connectors = allConnectors
        return ResourceInventory(
            behaviorSkills: allBehaviorSkills(connectors: connectors),
            connectors: connectors,
            localTools: allLocalTools
        )
    }

    var resolver: SkillResolver {
        let shelfAvailabilityPolicy = WorkspaceShelfRuntimePolicy.resolvedShelfAvailabilityPolicy(for: task.workspace)
        let standaloneTools = allLocalTools.filter { $0.skill == nil }
        let standaloneSnapshots = standaloneTools.map(LocalToolSnapshotConfig.init(localTool:))
        let liveConnectors = allConnectors
        let liveSkills = allBehaviorSkills(connectors: liveConnectors)

        var liveCLICommands = Set(
            allLocalTools
                .filter { $0.toolType != "mcp" && !$0.command.isEmpty }
                .map(\.command)
        )
        if Self.shouldExposeBrowserBridge(for: task, shelfAvailabilityPolicy: shelfAvailabilityPolicy) {
            liveCLICommands.insert("astra-browser")
        }

        var liveEnvVars: [String: String] = [:]
        for skill in liveSkills {
            for (key, value) in skill.environmentVariables {
                liveEnvVars[key] = value
            }
        }

        let connEnvVars = ConnectorRuntimeProjection(
            connectors: liveConnectors,
            secretStore: secretStore,
            credentialExposurePolicy: connectorCredentialExposurePolicy
        )
            .environmentVariables()

        return SkillResolver(
            effectiveSnapshots: effectiveSkillSnapshots,
            detachedSnapshots: detachedSkillSnapshots,
            standaloneToolSnapshots: standaloneSnapshots,
            liveLocalToolCommands: liveCLICommands,
            liveSkillEnvVars: liveEnvVars,
            connectorEnvVars: connEnvVars
        )
    }

    var allBehaviorSkills: [Skill] {
        allBehaviorSkills(connectors: allConnectors)
    }

    private func allBehaviorSkills(connectors: [Connector]) -> [Skill] {
        // Enabled package definitions are authoritative over stale live task
        // references with the same package/component identity.
        var combined = enabledPackageSkills() + task.skills
        for connector in connectors {
            guard let skill = connector.skill else { continue }
            combined.append(skill)
        }
        return uniqueSkills(combined)
    }

    var allConnectors: [Connector] {
        let enabledGlobalIDs = Set(task.workspace?.enabledGlobalConnectorIDs ?? [])
        let workspaceID = task.workspace?.id
        let packageSkills = enabledPackageSkills()
        let fromSkills = (task.skills + packageSkills).flatMap(\.connectors).filter { connector in
            if connector.isGlobal {
                return enabledGlobalIDs.contains(connector.id.uuidString)
                    || enabledPackageConnectorSpecs().contains { CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector) }
            }
            return connector.workspace?.id == workspaceID
        }
        let standalone = task.workspace?.connectors.filter { $0.skill == nil && !$0.isGlobal } ?? []
        var all = fromSkills + standalone + enabledPackageConnectors()

        if let ws = task.workspace, !ws.enabledGlobalConnectorIDs.isEmpty {
            let enabledIDs = Set(ws.enabledGlobalConnectorIDs)
            all += globalConnectors().filter { enabledIDs.contains($0.id.uuidString) }
        }

        var seen = Set<UUID>()
        let unique = all
            .filter { seen.insert($0.id).inserted }
            .filter(ConnectorSecurityPolicy.isRuntimeSafe)
        // Inventory ranking may use configuration/readiness, but never task
        // prose. Turn evidence is applied only after activation below.
        return ConnectorPreflightService.preferredRuntimeConnectors(
            from: unique,
            contextText: ""
        )
    }

    var allLocalTools: [LocalTool] {
        let packageSkills = enabledPackageSkills()
        let fromSkills = (task.skills + packageSkills).flatMap(\.localTools)
        let standalone = task.workspace?.localTools.filter { $0.skill == nil && !$0.isGlobal } ?? []
        var all = fromSkills + standalone + enabledPackageLocalTools()

        if let ws = task.workspace, !ws.enabledGlobalToolIDs.isEmpty {
            let enabledIDs = Set(ws.enabledGlobalToolIDs)
            all += globalLocalTools().filter { enabledIDs.contains($0.id.uuidString) }
        }

        var seen = Set<UUID>()
        return all.filter {
            seen.insert($0.id).inserted
                && LocalToolSecurityPolicy.isSafe(command: $0.command, arguments: $0.arguments)
        }
    }

    var enabledBrowserAdapters: [String] {
        Self.enabledBrowserAdapters(
            for: task.workspace,
            packages: CapabilityRuntimeResourceMatcher.packageDefinitions(),
            approvalRecords: CapabilityApprovalStore().records()
        )
    }

    var enabledMCPServerManifests: [RunPermissionManifest.MCPServer] {
        Self.enabledMCPServerManifests(
            for: task.workspace,
            packages: CapabilityRuntimeResourceMatcher.packageDefinitions(),
            approvalRecords: CapabilityApprovalStore().records()
        )
    }

    private func enabledPackageSkills() -> [Skill] {
        let packages = enabledCapabilityPackages()
        let candidates = workspaceSkills() + globalSkills()
        let directlyMatched = packages.flatMap { package in
            package.skills.compactMap { pluginSkill in
                CapabilityRuntimeResourceMatcher.preferredPackageSkill(
                    pluginSkill,
                    package: package,
                    candidates: candidates
                )
            }
        }
        let resourceOwners = (enabledPackageConnectors().compactMap(\.skill) + enabledPackageLocalTools().compactMap(\.skill))
            .filter { skill in
                candidates.contains { $0.id == skill.id }
            }
        return uniqueSkills(directlyMatched + resourceOwners)
    }

    private func enabledPackageConnectors() -> [Connector] {
        let specs = enabledPackageConnectorSpecs()
        guard !specs.isEmpty else { return [] }
        let candidates = workspaceConnectors() + globalConnectors()
        return uniqueConnectors(candidates.filter { connector in
            specs.contains { CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector) }
        })
    }

    private func enabledPackageLocalTools() -> [LocalTool] {
        let specs = enabledPackageLocalToolSpecs()
        guard !specs.isEmpty else { return [] }
        let candidates = workspaceLocalTools() + globalLocalTools()
        return uniqueTools(candidates.filter { tool in
            specs.contains { CapabilityRuntimeResourceMatcher.toolMatches($0, tool: tool) }
        })
    }

    private func enabledPackageConnectorSpecs() -> [PluginConnector] {
        enabledCapabilityPackages().flatMap(\.connectors)
    }

    private func enabledPackageLocalToolSpecs() -> [PluginLocalTool] {
        enabledCapabilityPackages().flatMap(\.localTools)
    }

    private func enabledCapabilityPackages() -> [PluginPackage] {
        CapabilityRuntimeResourceMatcher.enabledPackages(for: task.workspace)
    }

    private func workspaceSkills() -> [Skill] {
        task.workspace?.skills.filter { !$0.isGlobal } ?? []
    }

    private func workspaceConnectors() -> [Connector] {
        task.workspace?.connectors.filter { !$0.isGlobal } ?? []
    }

    private func workspaceLocalTools() -> [LocalTool] {
        task.workspace?.localTools.filter { !$0.isGlobal } ?? []
    }

    private func globalSkills() -> [Skill] {
        guard let ctx = task.modelContext else {
            return task.workspace?.skills.filter { $0.isGlobal } ?? []
        }
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })
        do {
            return try ctx.fetch(descriptor)
        } catch {
            AppLogger.error(
                "Failed to load global skills for capability resolution: \(error.localizedDescription)",
                category: "Capabilities",
                taskID: task.id
            )
            return task.workspace?.skills.filter { $0.isGlobal } ?? []
        }
    }

    private func globalConnectors() -> [Connector] {
        guard let ctx = task.modelContext else {
            return task.workspace?.connectors.filter { $0.isGlobal } ?? []
        }
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
        do {
            return try ctx.fetch(descriptor)
        } catch {
            AppLogger.error(
                "Failed to load global connectors for capability resolution: \(error.localizedDescription)",
                category: "Capabilities",
                taskID: task.id
            )
            return task.workspace?.connectors.filter { $0.isGlobal } ?? []
        }
    }

    private func globalLocalTools() -> [LocalTool] {
        guard let ctx = task.modelContext else {
            return task.workspace?.localTools.filter { $0.isGlobal } ?? []
        }
        let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })
        do {
            return try ctx.fetch(descriptor)
        } catch {
            AppLogger.error(
                "Failed to load global local tools for capability resolution: \(error.localizedDescription)",
                category: "Capabilities",
                taskID: task.id
            )
            return task.workspace?.localTools.filter { $0.isGlobal } ?? []
        }
    }

    private func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var order: [String] = []
        var selected: [String: Skill] = [:]
        for skill in skills {
            let key = logicalSkillKey(skill)
            guard let existing = selected[key] else {
                selected[key] = skill
                order.append(key)
                continue
            }
            if prefersNewerOwnedSkill(skill, over: existing) {
                selected[key] = skill
            }
        }
        return order.compactMap { selected[$0] }
    }

    private func logicalSkillKey(_ skill: Skill) -> String {
        let packageID = skill.originPackageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let componentID = skill.originComponentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !packageID.isEmpty, !componentID.isEmpty else {
            return "skill:\(skill.id.uuidString)"
        }
        return "package:\(packageID):\(componentID)"
    }

    private func prefersNewerOwnedSkill(_ candidate: Skill, over existing: Skill) -> Bool {
        if let candidateVersion = candidate.originPackageVersion.flatMap(SemanticVersion.init(string:)),
           let existingVersion = existing.originPackageVersion.flatMap(SemanticVersion.init(string:)),
           candidateVersion != existingVersion {
            return candidateVersion > existingVersion
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.id.uuidString < existing.id.uuidString
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return connectors.filter { seen.insert($0.id).inserted }
    }

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        var seen = Set<UUID>()
        return tools.filter { seen.insert($0.id).inserted }
    }

    static func enabledBrowserAdapters(
        for workspace: Workspace?,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord] = []
    ) -> [String] {
        guard let workspace else { return [] }
        let enabledPackageIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledPackageIDs.isEmpty else { return [] }
        let context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            approvalRecords: approvalRecords
        )

        var seen = Set<String>()
        var adapters: [String] = []
        for package in packages
            where enabledPackageIDs.contains(package.id)
                && CapabilityCatalogPolicy.decision(for: package, context: context).canRun {
            for adapter in package.browserAdapters {
                guard let normalized = BrowserSiteAdapterID.normalized(adapter),
                      seen.insert(normalized).inserted else { continue }
                adapters.append(normalized)
            }
        }
        return adapters
    }

    static func enabledMCPServerManifests(
        for workspace: Workspace?,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord] = []
    ) -> [RunPermissionManifest.MCPServer] {
        guard let workspace else { return [] }
        let enabledPackageIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledPackageIDs.isEmpty else { return [] }
        // Single-user admin model: the manifest reflects what actually runs,
        // so it uses the same currentUser context as MCPRuntimeProjection.
        let context = CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: approvalRecords
        )

        return packages
            .filter { enabledPackageIDs.contains($0.id) }
            .filter { CapabilityCatalogPolicy.decision(for: $0, context: context).canRun }
            .flatMap { package in
                package.mcpServers.map { server in
                    RunPermissionManifest.MCPServer(
                        id: server.id,
                        packageID: package.id,
                        displayName: server.displayName,
                        transport: server.transport.rawValue,
                        allowedTools: server.allowedTools,
                        excludedTools: server.excludedTools,
                        resourcesEnabled: server.resourcesEnabled,
                        promptsEnabled: server.promptsEnabled,
                        trustLevel: server.trustLevel.rawValue
                    )
                }
            }
            .sorted {
                if $0.packageID != $1.packageID { return $0.packageID < $1.packageID }
                return $0.id < $1.id
            }
    }

    func promptScope(contextText: String = "") -> TaskCapabilityPromptScope {
        makePromptScope(contextText: contextText, forcePrune: false)
    }

    func activationScope(contextText: String = "") -> TaskCapabilityPromptScope {
        makePromptScope(contextText: contextText, forcePrune: true)
    }

    private func makePromptScope(contextText: String, forcePrune: Bool) -> TaskCapabilityPromptScope {
        let shelfAvailabilityPolicy = WorkspaceShelfRuntimePolicy.resolvedShelfAvailabilityPolicy(for: task.workspace)
        let inventory = resourceInventory
        let connectors = inventory.connectors
        var tools = inventory.localTools
        let enabledPackageIDs = enabledCapabilityPackages().map(\.id)
        if Self.shouldExposeBrowserBridge(
            for: task,
            contextText: contextText,
            shelfAvailabilityPolicy: shelfAvailabilityPolicy
        ),
           !tools.contains(where: { $0.command == "astra-browser" }) {
            tools.append(Self.browserBridgeTool())
        }
        let skills = inventory.behaviorSkills

        let shouldPruneForRuntimeScope = Self.shouldPruneCapabilitiesForTask(
            task: task,
            contextText: contextText,
            shelfAvailabilityPolicy: shelfAvailabilityPolicy
        )
            || Self.hasRuntimeScopedCapabilities(skills: skills, connectors: connectors, localTools: tools)

        guard forcePrune || shouldPruneForRuntimeScope else {
            return makePromptScope(
                skills: skills,
                connectors: connectors,
                localTools: tools,
                prunedForBrowserTask: false,
                excludedSkillNames: [],
                enabledPackageIDs: enabledPackageIDs,
                contextText: contextText
            )
        }

        let searchableText = Self.searchableTaskText(task: task, contextText: contextText)
        // The inventory keeps one copy of each logical skill, but a resource's
        // `skill` back-reference still points at whichever copy owns it — and
        // that can be the copy dedupe discarded (a global "Jira Agent" and a
        // workspace copy of the same package component both exist; the newer
        // one wins). Matching ownership on raw object identity then orphans the
        // resource: the skill is in scope, its connector is unreachable, and no
        // wording of the request can recover it. Resolve through the logical
        // identity the user actually sees.
        let canonicalSkillsByKey = Dictionary(
            skills.map { (logicalSkillKey($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func canonicalSkill(_ skill: Skill?) -> Skill? {
            guard let skill else { return nil }
            return canonicalSkillsByKey[logicalSkillKey(skill)] ?? skill
        }

        var includedSkills: [Skill] = []
        var includedSkillIDs = Set<UUID>()

        func includeSkill(_ skill: Skill?) {
            guard let skill = canonicalSkill(skill),
                  includedSkillIDs.insert(skill.id).inserted else { return }
            includedSkills.append(skill)
        }

        for skill in skills where Self.shouldKeepSkill(skill, taskText: searchableText) {
            includeSkill(skill)
        }

        // A connector whose credentials the user already approved for this task
        // is settled business: they were asked about this exact connector, in
        // this exact task, and said yes. Re-deciding that from the wording of a
        // later turn is how "you have accessto jita ,, give methe data" — one
        // transposed letter — silently strips the connector the run has already
        // been using, and the agent reports it has no access to a tool the user
        // just authorized. Word overlap is a hint for discovering capabilities;
        // it is not evidence for revoking an approved one.
        //
        // This widens scope, never exposure: the projection still gates every
        // credential through `connectorCredentialExposurePolicy`, which is
        // built from these same approved labels.
        let approvedConnectorIDs = Self.approvedCredentialConnectorIDs(
            in: TaskRuntimePermissionGrants.approvedCredentialLabels(
                for: task,
                runtime: runtime,
                additionalGrants: additionalCredentialGrants
            )
        )

        let matchedConnectors = connectors.filter { connector in
            Self.matchesConnector(connector, taskText: searchableText)
        }
        let relevantConnectors = ConnectorPreflightService.preferredRuntimeConnectors(
            from: matchedConnectors,
            contextText: searchableText
        ) + connectors.filter { connector in
            approvedConnectorIDs.contains(connector.id)
                && !matchedConnectors.contains { $0.id == connector.id }
        }
        for connector in relevantConnectors {
            includeSkill(connector.skill)
        }

        let includedConnectors = connectors.filter { connector in
            if relevantConnectors.contains(where: { $0.id == connector.id }) {
                return true
            }
            guard let skill = canonicalSkill(connector.skill) else { return false }
            return includedSkillIDs.contains(skill.id)
        }

        let includedLocalTools = tools.filter { tool in
            if let skill = canonicalSkill(tool.skill) {
                return includedSkillIDs.contains(skill.id)
            }
            return Self.matchesLocalTool(tool, taskText: searchableText)
        }

        let excludedNames = skills
            .filter { !includedSkillIDs.contains($0.id) }
            .map(\.name)

        return makePromptScope(
            skills: includedSkills,
            connectors: includedConnectors,
            localTools: includedLocalTools,
            prunedForBrowserTask: true,
            excludedSkillNames: excludedNames,
            enabledPackageIDs: enabledPackageIDs.filter { packageID in
                includedSkills.contains { $0.originPackageID == packageID }
                    || Self.packageID(packageID, matchesTaskText: searchableText)
            },
            contextText: contextText
        )
    }

    func resolvedScope(_ scope: TaskCapabilityResolutionScope) -> TaskCapabilityPromptScope {
        switch scope {
        case .fullInventory:
            let shelfAvailabilityPolicy = WorkspaceShelfRuntimePolicy.resolvedShelfAvailabilityPolicy(for: task.workspace)
            let inventory = resourceInventory
            let connectors = inventory.connectors
            var tools = inventory.localTools
            if Self.shouldExposeBrowserBridge(for: task, contextText: "", shelfAvailabilityPolicy: shelfAvailabilityPolicy),
               !tools.contains(where: { $0.command == "astra-browser" }) {
                tools.append(Self.browserBridgeTool())
            }
            return makePromptScope(
                skills: inventory.behaviorSkills,
                connectors: connectors,
                localTools: tools,
                prunedForBrowserTask: false,
                excludedSkillNames: [],
                enabledPackageIDs: enabledCapabilityPackages().map(\.id),
                contextText: ""
            )
        case .providerLaunch(let contextText):
            return promptScope(contextText: contextText)
        }
    }

    var connectorCredentialExposurePolicy: ConnectorRuntimeProjection.CredentialExposurePolicy {
        return ConnectorRuntimeProjection.CredentialExposurePolicy.approvedLabels(
            Set(TaskRuntimePermissionGrants.approvedCredentialLabels(
                for: task,
                runtime: runtime,
                additionalGrants: additionalCredentialGrants
            ))
        )
    }

    private var effectiveSkillSnapshots: [SkillSnapshotConfig] {
        let liveSnapshots = allBehaviorSkills.map(SkillSnapshotConfig.init(skill:))
        guard !task.skillSnapshots.isEmpty else { return liveSnapshots }
        guard !liveSnapshots.isEmpty else { return task.skillSnapshots }

        var combined = liveSnapshots
        var seenIDs = Set(liveSnapshots.compactMap(\.id))
        var seenNames = Set(liveSnapshots.map { $0.name.lowercased() })

        for snapshot in task.skillSnapshots {
            let hasMatchingID = snapshot.id.map { seenIDs.contains($0) } ?? false
            let nameKey = snapshot.name.lowercased()
            guard !hasMatchingID && !seenNames.contains(nameKey) else { continue }
            combined.append(snapshot)
            if let id = snapshot.id {
                seenIDs.insert(id)
            }
            seenNames.insert(nameKey)
        }

        return combined
    }

    private var detachedSkillSnapshots: [SkillSnapshotConfig] {
        guard !task.skillSnapshots.isEmpty else { return [] }
        let liveSkills = allBehaviorSkills
        guard !liveSkills.isEmpty else { return task.skillSnapshots }

        let liveIDs = Set(liveSkills.map { $0.id.uuidString })
        let liveNames = Set(liveSkills.map { $0.name.lowercased() })

        return task.skillSnapshots.filter { snapshot in
            if let id = snapshot.id, liveIDs.contains(id) {
                return false
            }
            return !liveNames.contains(snapshot.name.lowercased())
        }
    }

    private func makePromptScope(
        skills: [Skill],
        connectors: [Connector],
        localTools: [LocalTool],
        prunedForBrowserTask: Bool,
        excludedSkillNames: [String],
        enabledPackageIDs: [String],
        contextText: String
    ) -> TaskCapabilityPromptScope {
        let skillIDs = Set(skills.map(\.id))
        let liveSnapshots = skills.map(SkillSnapshotConfig.init(skill:))
        let liveSnapshotIDs = Set(liveSnapshots.compactMap(\.id))
        let liveSnapshotNames = Set(liveSnapshots.map { $0.name.lowercased() })
        let standaloneTools = localTools.filter { $0.skill == nil }
        let standaloneSnapshots = standaloneTools.map(LocalToolSnapshotConfig.init(localTool:))
        let liveCLICommands = Set(
            localTools
                .filter { $0.toolType != "mcp" && !$0.command.isEmpty }
                .map(\.command)
        )

        var detachedSnapshots = task.skillSnapshots.filter { snapshot in
            if let id = snapshot.id, liveSnapshotIDs.contains(id) {
                return false
            }
            guard !liveSnapshotNames.contains(snapshot.name.lowercased()) else {
                return false
            }
            if !prunedForBrowserTask {
                return true
            }
            return Self.matchesSnapshot(snapshot, taskText: Self.searchableTaskText(task: task, contextText: contextText))
        }

        if !prunedForBrowserTask {
            detachedSnapshots = self.detachedSkillSnapshots
        }

        var liveEnvVars: [String: String] = [:]
        for skill in skills {
            for (key, value) in skill.environmentVariables {
                liveEnvVars[key] = value
            }
        }

        let connectorEnvVars = ConnectorRuntimeProjection(
            connectors: connectors,
            secretStore: secretStore,
            credentialExposurePolicy: connectorCredentialExposurePolicy
        )
            .environmentVariables()

        let resolver = SkillResolver(
            effectiveSnapshots: liveSnapshots + detachedSnapshots,
            detachedSnapshots: detachedSnapshots,
            standaloneToolSnapshots: standaloneSnapshots,
            liveLocalToolCommands: liveCLICommands,
            liveSkillEnvVars: liveEnvVars,
            connectorEnvVars: connectorEnvVars
        )

        let scopedTools = localTools.filter { tool in
            guard let skill = tool.skill else { return true }
            return skillIDs.contains(skill.id)
        }

        return TaskCapabilityPromptScope(
            resolver: resolver,
            behaviorSkills: skills,
            connectors: connectors,
            localTools: scopedTools,
            enabledBrowserAdapters: enabledBrowserAdapters,
            prunedForBrowserTask: prunedForBrowserTask,
            excludedSkillNames: excludedSkillNames,
            enabledPackageIDs: Self.uniqueStrings(enabledPackageIDs)
        )
    }

    private static func packageID(_ packageID: String, matchesTaskText taskText: String) -> Bool {
        guard packageID == "github-workflow" else { return false }
        let tokens = taskTextTokens(taskText)
        let tokenSet = Set(tokens)
        if !tokenSet.isDisjoint(with: ["github", "ci", "pr", "prs"]) {
            return true
        }
        return taskTextContainsTokenPhrase(tokens, matching: ["pull", "request"])
            || taskTextContainsTokenPhrase(tokens, matching: ["pull", "requests"])
            || taskTextContainsTokenPhrase(tokens, matching: ["workflow", "run"])
            || taskTextContainsTokenPhrase(tokens, matching: ["workflow", "runs"])
            || taskTextContainsQualifiedIssueReference(tokens)
    }

    private static func taskTextTokens(_ taskText: String) -> [String] {
        normalizedSearchText(taskText).split(separator: " ").map(String.init)
    }

    private static func taskTextContainsTokenPhrase(_ tokens: [String], matching phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        for startIndex in 0...(tokens.count - phrase.count) {
            if tokens[startIndex..<(startIndex + phrase.count)].elementsEqual(phrase) {
                return true
            }
        }
        return false
    }

    private static func taskTextContainsQualifiedIssueReference(_ tokens: [String]) -> Bool {
        let issueTokens: Set<String> = ["issue", "issues"]
        for index in tokens.indices where issueTokens.contains(tokens[index]) {
            let previous = index > tokens.startIndex ? tokens[index - 1] : nil
            let next = index < tokens.index(before: tokens.endIndex) ? tokens[index + 1] : nil
            if previous == "gh" || next == "gh" {
                return true
            }
        }
        return false
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func shouldPruneCapabilitiesForTask(
        task: AgentTask,
        contextText: String,
        shelfAvailabilityPolicy: ShelfAvailabilityPolicy? = nil
    ) -> Bool {
        let text = searchableTaskText(task: task, contextText: contextText)
        guard !text.isEmpty else { return false }
        if shouldExposeBrowserBridge(
            for: task,
            contextText: contextText,
            shelfAvailabilityPolicy: shelfAvailabilityPolicy
        ),
           browserIntentTerms.contains(where: { text.contains($0) }) {
            return true
        }
        if hasStandaloneArtifactIntent(text) {
            return true
        }
        return false
    }

    private static func hasRuntimeScopedCapabilities(
        skills: [Skill],
        connectors: [Connector],
        localTools: [LocalTool]
    ) -> Bool {
        if !connectors.isEmpty || !localTools.isEmpty {
            return true
        }

        return skills.contains { skill in
            !skill.allowedTools.isEmpty
                || !skill.disallowedTools.isEmpty
                || !skill.customTools.isEmpty
                || !skill.environmentKeys.isEmpty
        }
    }

    private static func hasStandaloneArtifactIntent(_ text: String) -> Bool {
        let hasAction = artifactActionTerms.contains { text.contains($0) }
        let hasTarget = artifactTargetTerms.contains { text.contains($0) }
        return hasAction && hasTarget
    }

    static func shouldExposeBrowserBridge(
        for task: AgentTask,
        contextText: String = "",
        shelfAvailabilityPolicy: ShelfAvailabilityPolicy? = nil
    ) -> Bool {
        guard canPresentBrowserShelf(for: task, shelfAvailabilityPolicy: shelfAvailabilityPolicy) else { return false }
        let state = ShelfBrowserBridgeRegistry.shared.promptState(for: task.id)
        guard state.isExposed else { return false }
        if state.isPresented || state.hasCurrentURL {
            return true
        }
        let text = searchableTaskText(task: task, contextText: contextText)
        return explicitBrowserControlTerms.contains { text.contains($0) }
    }

    private static func canPresentBrowserShelf(
        for task: AgentTask,
        shelfAvailabilityPolicy: ShelfAvailabilityPolicy? = nil
    ) -> Bool {
        WorkspaceShelfRuntimePolicy.canPresentBrowserShelf(
            for: task.workspace,
            shelfAvailabilityPolicy: shelfAvailabilityPolicy
        )
    }

    private static func browserBridgeTool() -> LocalTool {
        LocalTool(
            name: "Shelf Browser Control",
            toolDescription: "Controls ASTRA's current Shelf browser session through ASTRA_BROWSER_URL. Analyze uses v2 by default; verify outcomeVerified after actions.",
            icon: "globe",
            toolType: "cli",
            command: "astra-browser"
        )
    }

    /// Connector IDs named by approved credential labels of the form
    /// `connector:<uuid>:<CREDENTIAL_KEY>`. Labels that are not connector
    /// scoped (a bare `GCP_PROJECT`, say) carry no connector identity and are
    /// ignored here.
    private static func approvedCredentialConnectorIDs(in labels: [String]) -> Set<UUID> {
        Set(labels.compactMap { label -> UUID? in
            let parts = label.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "connector" else { return nil }
            return UUID(uuidString: String(parts[1]))
        })
    }

    private static func shouldKeepSkill(_ skill: Skill, taskText: String) -> Bool {
        if Skill.isBuiltInName(skill.name) {
            return true
        }
        return matchesSkill(skill, taskText: taskText)
    }

    private static func matchesSkill(_ skill: Skill, taskText: String) -> Bool {
        if skill.connectors.contains(where: { matchesConnector($0, taskText: taskText) }) {
            return true
        }
        if skill.localTools.contains(where: { matchesLocalTool($0, taskText: taskText) }) {
            return true
        }
        return matchesCapabilityText(
            [
                skill.name,
                skill.skillDescription
            ].joined(separator: " "),
            taskText: taskText
        )
    }

    private static func matchesConnector(_ connector: Connector, taskText: String) -> Bool {
        let normalizedTask = normalizedSearchText(taskText)
        guard !normalizedTask.isEmpty else { return false }
        let serviceType = normalizedSearchText(connector.serviceType)
        let aliases = serviceAliases[serviceType] ?? [serviceType]
        if aliases.contains(where: { containsTokenPhrase(normalizedTask, phrase: $0) }) {
            return true
        }

        if serviceType == "jira" {
            if taskText.range(
                of: #"\b[A-Z][A-Z0-9]{1,15}-[0-9]+\b"#,
                options: .regularExpression
            ) != nil {
                return true
            }
            let configuredProjects = jiraProjectKeys(
                connector.config["JIRA_PROJECTS"] ?? ""
            )
            if jiraProjectKeyMentioned(
                in: taskText,
                configuredProjects: configuredProjects
            ) {
                return true
            }
        }

        if let host = URL(string: connector.baseURL)?.host,
           !host.isEmpty,
           containsTokenPhrase(normalizedTask, phrase: normalizedSearchText(host)) {
            return true
        }

        return matchesCapabilityText(
            [
                connector.name,
                connector.serviceType,
                connector.connectorDescription,
                connector.baseURL
            ].joined(separator: " "),
            taskText: taskText
        )
    }

    private static func matchesLocalTool(_ tool: LocalTool, taskText: String) -> Bool {
        matchesCapabilityText(
            [
                tool.name,
                tool.command,
                tool.toolDescription,
                tool.arguments
            ].joined(separator: " "),
            taskText: taskText
        )
    }

    private static func matchesSnapshot(_ snapshot: SkillSnapshotConfig, taskText: String) -> Bool {
        let connectorText = snapshot.connectorSnapshots?
            .map { connector in
                [
                    connector.name,
                    connector.serviceType,
                    connector.description,
                    connector.baseURL
                ].joined(separator: " ")
            }
            .joined(separator: " ") ?? ""
        let localToolText = snapshot.localToolSnapshots?
            .map { tool in
                [
                    tool.name,
                    tool.command,
                    tool.description
                ].joined(separator: " ")
            }
            .joined(separator: " ") ?? ""

        return matchesCapabilityText(
            [
                snapshot.name,
                snapshot.description,
                connectorText,
                localToolText
            ].joined(separator: " "),
            taskText: taskText
        )
    }

    private static func matchesCapabilityText(_ capabilityText: String, taskText: String) -> Bool {
        let capability = normalizedSearchText(capabilityText)
        guard !capability.isEmpty else { return false }
        let taskTokens = searchTokens(taskText)
        guard !taskTokens.isEmpty else { return false }
        let capabilityTokens = searchTokens(capability)
        return !taskTokens.isDisjoint(with: capabilityTokens)
    }

    private static func searchableTaskText(task: AgentTask, contextText: String) -> String {
        let currentTurn = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTurn.isEmpty {
            return normalizedSearchText(currentTurn)
        }
        return normalizedSearchText(TaskContextStateManager.activeObjectiveText(for: task))
    }

    private static func containsTokenPhrase(_ normalizedText: String, phrase: String) -> Bool {
        let normalizedPhrase = normalizedSearchText(phrase)
        guard !normalizedPhrase.isEmpty else { return false }
        return " \(normalizedText) ".contains(" \(normalizedPhrase) ")
    }

    private static func jiraProjectKeys(_ raw: String) -> Set<String> {
        Set(
            raw.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
                .map { $0.uppercased() }
                .filter { !$0.isEmpty }
        )
    }

    private static func jiraProjectKeyMentioned(
        in text: String,
        configuredProjects: Set<String>
    ) -> Bool {
        guard !configuredProjects.isEmpty else { return false }
        let tokens = text
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map { $0.uppercased() }
        return tokens.contains(where: configuredProjects.contains)
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchTokens(_ text: String) -> Set<String> {
        let normalized = normalizedSearchText(text)
        var tokens = Set<String>()
        for token in normalized.split(separator: " ").map(String.init) {
            if token == "pr" || token == "prs" {
                tokens.insert("pr")
                tokens.insert("prs")
                continue
            }
            guard token.count >= 3, !genericCapabilityTokens.contains(token) else { continue }
            tokens.insert(token)
            if token.count > 4, token.hasSuffix("s") {
                tokens.insert(String(token.dropLast()))
            }
        }
        if normalized.contains("pull request") || normalized.contains("pull requests") {
            tokens.insert("pr")
            tokens.insert("prs")
        }
        return tokens
    }

    private static let browserIntentTerms: [String] = [
        "browser",
        "page",
        "website",
        "webpage",
        "web page",
        "current site",
        "current tab",
        "email",
        "emails",
        "mail",
        "inbox",
        "outlook",
        "link",
        "url",
        "google docs",
        "google drive",
        "drive",
        "document",
        "doc",
        "open "
    ]

    private static let explicitBrowserControlTerms: [String] = [
        "browser",
        "current site",
        "current tab",
        "click",
        "fill",
        "navigate",
        "screenshot",
        "read page",
        "inspect page",
        "use browser",
        "open url",
        "outlook",
        "email",
        "emails",
        "mail",
        "inbox",
        "google docs",
        "google drive"
    ]

    private static let artifactActionTerms: [String] = [
        "build",
        "create",
        "deliver",
        "develop",
        "generate",
        "implement",
        "make",
        "produce",
        "render",
        "scaffold",
        "write"
    ]

    private static let artifactTargetTerms: [String] = [
        "app",
        "artifact",
        "demo",
        "design",
        "doc",
        "document",
        "file",
        "homepage",
        "html",
        "javascript",
        "js",
        "landing page",
        "mockup",
        "page",
        "prototype",
        "report",
        "site",
        "web page",
        "webpage",
        "website"
    ]

    private static let genericCapabilityTokens: Set<String> = [
        "agent",
        "and",
        "api",
        "app",
        "after",
        "before",
        "browser",
        "capability",
        "check",
        "cloud",
        "code",
        "content",
        "create",
        "current",
        "data",
        "delete",
        "deliver",
        "develop",
        "doc",
        "document",
        "docker",
        "download",
        "drive",
        "file",
        "files",
        "for",
        "forward",
        "from",
        "generate",
        "get",
        "google",
        "implement",
        "inspect",
        "list",
        "local",
        "look",
        "manage",
        "make",
        "must",
        "open",
        "only",
        "page",
        "produce",
        "project",
        "query",
        "read",
        "render",
        "reply",
        "resource",
        "resources",
        "scaffold",
        "search",
        "service",
        "shared",
        "show",
        "summarize",
        "summary",
        "task",
        "the",
        "this",
        "through",
        "tool",
        "tools",
        "use",
        "user",
        "via",
        "web",
        "when",
        "with",
        "work",
        "workflow",
        "workspace",
        "write"
    ]

    private static let serviceAliases: [String: [String]] = [
        "jira": ["jira", "atlassian"],
        "github": ["github", "gh"],
        "gcp": ["gcp", "google cloud", "bigquery"],
        "slack": ["slack"],
        "outlook": ["outlook", "microsoft 365"],
        "graph": ["microsoft graph", "graph mail"]
    ]
}

struct TaskCapabilityPromptScope {
    let resolver: SkillResolver
    let behaviorSkills: [Skill]
    let connectors: [Connector]
    let localTools: [LocalTool]
    let enabledBrowserAdapters: [String]
    let prunedForBrowserTask: Bool
    let excludedSkillNames: [String]
    let enabledPackageIDs: [String]

    var exposesBrowserBridge: Bool {
        localTools.contains { $0.command == "astra-browser" }
    }
}
