import Foundation
import SwiftData
import ASTRACore

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

struct TaskCapabilityResolver {
    private let task: AgentTask

    init(task: AgentTask) {
        self.task = task
    }

    var resolver: SkillResolver {
        let standaloneTools = allLocalTools.filter { $0.skill == nil }
        let standaloneSnapshots = standaloneTools.map(LocalToolSnapshotConfig.init(localTool:))
        let liveConnectors = allConnectors
        let liveSkills = allBehaviorSkills(connectors: liveConnectors)

        var liveCLICommands = Set(
            allLocalTools
                .filter { $0.toolType != "mcp" && !$0.command.isEmpty }
                .map(\.command)
        )
        if Self.shouldExposeBrowserBridge(for: task) {
            liveCLICommands.insert("astra-browser")
        }

        var liveEnvVars: [String: String] = [:]
        for skill in liveSkills {
            for (key, value) in skill.environmentVariables {
                liveEnvVars[key] = value
            }
        }

        let connEnvVars = ConnectorRuntimeProjection(connectors: liveConnectors)
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
        var combined = task.skills + enabledPackageSkills()
        for connector in connectors {
            guard let skill = connector.skill else { continue }
            combined.append(skill)
        }

        var seen = Set<UUID>()
        return combined.filter { seen.insert($0.id).inserted }
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
        let standalone = task.workspace?.connectors.filter { $0.skill == nil } ?? []
        var all = fromSkills + standalone + enabledPackageConnectors()

        if let ws = task.workspace, !ws.enabledGlobalConnectorIDs.isEmpty, let ctx = task.modelContext {
            let enabledIDs = Set(ws.enabledGlobalConnectorIDs)
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
            if let globals = try? ctx.fetch(descriptor) {
                all += globals.filter { enabledIDs.contains($0.id.uuidString) }
            }
        }

        var seen = Set<UUID>()
        let unique = all
            .filter { seen.insert($0.id).inserted }
            .filter(ConnectorSecurityPolicy.isRuntimeSafe)
        return ConnectorPreflightService.preferredRuntimeConnectors(
            from: unique,
            contextText: TaskContextStateManager.capabilitySearchText(for: task, contextText: "")
        )
    }

    var allLocalTools: [LocalTool] {
        let packageSkills = enabledPackageSkills()
        let fromSkills = (task.skills + packageSkills).flatMap(\.localTools)
        let standalone = task.workspace?.localTools.filter { $0.skill == nil } ?? []
        var all = fromSkills + standalone + enabledPackageLocalTools()

        if let ws = task.workspace, !ws.enabledGlobalToolIDs.isEmpty, let ctx = task.modelContext {
            let enabledIDs = Set(ws.enabledGlobalToolIDs)
            let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })
            if let globals = try? ctx.fetch(descriptor) {
                all += globals.filter { enabledIDs.contains($0.id.uuidString) }
            }
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
        let pluginSkills = packages.flatMap(\.skills)

        let candidates = workspaceSkills() + globalSkills()
        let directlyMatched = pluginSkills.isEmpty ? [] : candidates.filter { skill in
            pluginSkills.contains { CapabilityRuntimeResourceMatcher.skillMatches($0, skill: skill) }
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
        guard let ctx = task.modelContext else { return [] }
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })
        return (try? ctx.fetch(descriptor)) ?? []
    }

    private func globalConnectors() -> [Connector] {
        guard let ctx = task.modelContext else { return [] }
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
        return (try? ctx.fetch(descriptor)) ?? []
    }

    private func globalLocalTools() -> [LocalTool] {
        guard let ctx = task.modelContext else { return [] }
        let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })
        return (try? ctx.fetch(descriptor)) ?? []
    }

    private func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var seen = Set<UUID>()
        return skills.filter { seen.insert($0.id).inserted }
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
        let connectors = allConnectors
        var tools = allLocalTools
        let enabledPackageIDs = enabledCapabilityPackages().map(\.id)
        if Self.shouldExposeBrowserBridge(for: task, contextText: contextText),
           !tools.contains(where: { $0.command == "astra-browser" }) {
            tools.append(Self.browserBridgeTool())
        }
        let skills = allBehaviorSkills(connectors: connectors)

        let shouldPruneForRuntimeScope = Self.shouldPruneCapabilitiesForTask(task: task, contextText: contextText)
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
        var includedSkills: [Skill] = []
        var includedSkillIDs = Set<UUID>()

        func includeSkill(_ skill: Skill?) {
            guard let skill, includedSkillIDs.insert(skill.id).inserted else { return }
            includedSkills.append(skill)
        }

        for skill in skills where Self.shouldKeepSkill(skill, taskText: searchableText) {
            includeSkill(skill)
        }

        let relevantConnectors = connectors.filter { connector in
            Self.matchesConnector(connector, taskText: searchableText)
        }
        for connector in relevantConnectors {
            includeSkill(connector.skill)
        }

        let includedConnectors = connectors.filter { connector in
            if relevantConnectors.contains(where: { $0.id == connector.id }) {
                return true
            }
            guard let skill = connector.skill else { return false }
            return includedSkillIDs.contains(skill.id)
        }

        let includedLocalTools = tools.filter { tool in
            if let skill = tool.skill {
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
            let connectors = allConnectors
            var tools = allLocalTools
            if Self.shouldExposeBrowserBridge(for: task, contextText: ""),
               !tools.contains(where: { $0.command == "astra-browser" }) {
                tools.append(Self.browserBridgeTool())
            }
            return makePromptScope(
                skills: allBehaviorSkills(connectors: connectors),
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

        let connectorEnvVars = ConnectorRuntimeProjection(connectors: connectors)
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
        if ["github", "pull request", "pull requests", "issue", "issues", "ci", "workflow run"].contains(where: {
            taskText.contains($0)
        }) {
            return true
        }
        return taskTextContainsToken(taskText, matching: ["pr", "prs"])
    }

    private static func taskTextContainsToken(_ taskText: String, matching expectedTokens: Set<String>) -> Bool {
        taskText
            .split { !$0.isLetter && !$0.isNumber }
            .contains { expectedTokens.contains(String($0)) }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func shouldPruneCapabilitiesForTask(task: AgentTask, contextText: String) -> Bool {
        let text = searchableTaskText(task: task, contextText: contextText)
        guard !text.isEmpty else { return false }
        if shouldExposeBrowserBridge(for: task, contextText: contextText),
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

    static func shouldExposeBrowserBridge(for task: AgentTask, contextText: String = "") -> Bool {
        let state = ShelfBrowserBridgeRegistry.shared.promptState(for: task.id)
        guard state.isExposed else { return false }
        if state.isPresented || state.hasCurrentURL {
            return true
        }
        let text = searchableTaskText(task: task, contextText: contextText)
        return explicitBrowserControlTerms.contains { text.contains($0) }
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

    private static func shouldKeepSkill(_ skill: Skill, taskText: String) -> Bool {
        if Skill.isBuiltInName(skill.name) {
            return true
        }
        return matchesSkill(skill, taskText: taskText)
    }

    private static func matchesSkill(_ skill: Skill, taskText: String) -> Bool {
        return matchesCapabilityText(
            [
                skill.name,
                skill.skillDescription,
                skill.behaviorInstructions,
                skill.environmentKeys.joined(separator: " "),
                skill.localTools.map { "\($0.name) \($0.command) \($0.toolDescription)" }.joined(separator: " "),
                skill.connectors.map { "\($0.name) \($0.serviceType) \($0.connectorDescription) \($0.baseURL)" }.joined(separator: " ")
            ].joined(separator: " "),
            taskText: taskText
        )
    }

    private static func matchesConnector(_ connector: Connector, taskText: String) -> Bool {
        matchesCapabilityText(
            [
                connector.name,
                connector.serviceType,
                connector.connectorDescription,
                connector.baseURL,
                connector.configKeys.joined(separator: " "),
                connector.credentialKeys.joined(separator: " ")
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
                snapshot.behaviorInstructions,
                snapshot.environmentKeys.joined(separator: " "),
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
        normalizedSearchText(TaskContextStateManager.capabilitySearchText(for: task, contextText: contextText))
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
}
