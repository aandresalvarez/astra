import Foundation
import SwiftData
import ASTRACore

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
        if Self.hasBrowserBridge(for: task) {
            liveCLICommands.insert("astra-browser")
        }

        var liveEnvVars: [String: String] = [:]
        for skill in liveSkills {
            for (key, value) in skill.environmentVariables {
                liveEnvVars[key] = value
            }
        }

        var connEnvVars: [String: String] = [:]
        for connector in liveConnectors {
            for (key, value) in connector.allEnvironmentVariables {
                connEnvVars[key] = value
            }
        }

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
            contextText: [task.title, task.goal].joined(separator: "\n")
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
            packages: CapabilityRuntimeResourceMatcher.packageDefinitions()
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
        packages: [PluginPackage]
    ) -> [String] {
        guard let workspace else { return [] }
        let enabledPackageIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledPackageIDs.isEmpty else { return [] }

        var seen = Set<String>()
        var adapters: [String] = []
        for package in packages where enabledPackageIDs.contains(package.id) {
            for adapter in package.browserAdapters {
                guard let normalized = BrowserSiteAdapterID.normalized(adapter),
                      seen.insert(normalized).inserted else { continue }
                adapters.append(normalized)
            }
        }
        return adapters
    }

    func promptScope(contextText: String = "") -> TaskCapabilityPromptScope {
        let connectors = allConnectors
        var tools = allLocalTools
        if Self.hasBrowserBridge(for: task),
           !tools.contains(where: { $0.command == "astra-browser" }) {
            tools.append(Self.browserBridgeTool())
        }
        let skills = allBehaviorSkills(connectors: connectors)

        guard Self.shouldPruneForBrowserTask(task: task, contextText: contextText) else {
            return makePromptScope(
                skills: skills,
            connectors: connectors,
            localTools: tools,
            prunedForBrowserTask: false,
            excludedSkillNames: [],
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
            return includedSkillIDs.contains(skill.id) && Self.matchesConnector(connector, taskText: searchableText)
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
            contextText: contextText
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

        var connectorEnvVars: [String: String] = [:]
        for connector in connectors {
            for (key, value) in connector.allEnvironmentVariables {
                connectorEnvVars[key] = value
            }
        }

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
            excludedSkillNames: excludedSkillNames
        )
    }

    private static func shouldPruneForBrowserTask(task: AgentTask, contextText: String) -> Bool {
        guard hasBrowserBridge(for: task) else { return false }
        let text = searchableTaskText(task: task, contextText: contextText)
        return browserIntentTerms.contains { text.contains($0) }
    }

    private static func hasBrowserBridge(for task: AgentTask) -> Bool {
        !ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id).isEmpty
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
        if !skill.disallowedTools.isEmpty {
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
        if !taskTokens.isDisjoint(with: capabilityTokens) {
            return true
        }
        return capabilityTokens.contains { token in
            token.count >= 4 && taskText.contains(token)
        }
    }

    private static func searchableTaskText(task: AgentTask, contextText: String) -> String {
        normalizedSearchText([
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.constraints.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " "),
            contextText
        ].joined(separator: " "))
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
            guard token.count >= 3, !genericCapabilityTokens.contains(token) else { continue }
            tokens.insert(token)
            if token.count > 4, token.hasSuffix("s") {
                tokens.insert(String(token.dropLast()))
            }
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
        "link",
        "url",
        "google docs",
        "google drive",
        "drive",
        "document",
        "doc",
        "open "
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
        "current",
        "data",
        "doc",
        "document",
        "drive",
        "file",
        "files",
        "for",
        "from",
        "get",
        "google",
        "inspect",
        "list",
        "local",
        "look",
        "manage",
        "must",
        "open",
        "only",
        "page",
        "project",
        "query",
        "read",
        "resource",
        "resources",
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
}
