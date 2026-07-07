import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct CapabilityRuntimeIntegrityIssue: Equatable, Identifiable {
    enum Source: String {
        case enabledPackage = "enabled_package"
        case selectedPackageSkill = "selected_package_skill"
    }

    enum ResourceKind: String {
        case policy
        case skill
        case connector
        case localTool = "local_tool"
        case mcpServer = "mcp_server"
        case browserAdapter = "browser_adapter"
        case credential
        case executable
    }

    let packageID: String
    let packageName: String
    let source: Source
    let resourceKind: ResourceKind
    let resourceName: String
    let message: String

    var id: String {
        "\(source.rawValue):\(packageID):\(resourceKind.rawValue):\(resourceName)"
    }
}

enum CapabilityRuntimeIntegrityService {
    static func issues(
        for task: AgentTask,
        packages suppliedPackages: [PluginPackage]? = nil,
        checkExecutables: Bool = true,
        prerequisiteStatuses: [String: HealthStatus] = [:],
        policyContext: CapabilityCatalogPolicyContext? = nil,
        scope requestedScope: TaskCapabilityResolutionScope = .fullInventory,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        secretStore: SecretStore = KeychainSecretStore()
    ) -> [CapabilityRuntimeIntegrityIssue] {
        guard let workspace = task.workspace else { return [] }

        let packages = suppliedPackages ?? CapabilityRuntimeResourceMatcher.packageDefinitions()
        let rawEnabledPackageIDs = Set(workspace.enabledCapabilityIDs)
        let runtimePackPolicy = policyContext?.packPolicy ?? PackWorkspacePolicyProvider.resolvedPolicy(for: workspace)
        let runtimeEnabledPackageIDs = Set(
            CapabilityRuntimeResourceMatcher.enabledPackages(
                for: workspace,
                in: packages,
                approvalRecords: policyContext?.approvalRecords,
                packPolicy: runtimePackPolicy
            ).map(\.id)
        )
        let resolutionSnapshot = capabilityResolutionSnapshot ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: requestedScope.contextText
        )
        let resolvedScope = resolutionSnapshot.scope(requestedScope)
        let resolvedSkills = resolvedScope.behaviorSkills
        let resolvedConnectors = resolvedScope.connectors
        let resolvedTools = resolvedScope.localTools
        let enabledBrowserAdapters = Set(resolvedScope.enabledBrowserAdapters)
        // Resource EXISTENCE is judged against the full workspace inventory (before
        // focus-pruning), not the pruned launch scope. A workspace-enabled skill/
        // tool/connector that exists but was pruned for focus is still reachable —
        // the agent learns about it from the prompt's capability roster and can
        // invoke it under the permission gate — so it must not be reported as
        // "missing", which previously hard-failed the launch
        // (capability_runtime_resources_missing). Genuinely absent instances and
        // host problems (executable/auth/policy) below still surface only when
        // their package has a concrete runtime resource in the provider launch
        // scope.
        let reachableSkills = resolutionSnapshot.fullInventory.behaviorSkills
        let reachableConnectors = resolutionSnapshot.fullInventory.connectors
        let reachableTools = resolutionSnapshot.fullInventory.localTools
        let selectedSkillNames = liveSelectedPackageSkillNames(
            for: task,
            resolvedSkills: resolvedSkills,
            scope: requestedScope
        )
        let availableConnectors = availableConnectors(for: task)

        var checks: [(PluginPackage, CapabilityRuntimeIntegrityIssue.Source)] = []
        for package in packages where rawEnabledPackageIDs.contains(package.id) {
            if runtimeEnabledPackageIDs.contains(package.id) {
                guard shouldCheckEnabledPackage(
                    package,
                    task: task,
                    scope: requestedScope,
                    resolvedSkills: resolvedSkills,
                    resolvedConnectors: resolvedConnectors,
                    resolvedTools: resolvedTools
                ) else {
                    continue
                }
            } else if let policyContext {
                let decision = CapabilityCatalogPolicy.decision(for: package, context: policyContext)
                guard shouldReportPolicyDeniedEnabledPackage(decision) else { continue }
            } else {
                continue
            }
            checks.append((package, .enabledPackage))
        }

        for package in packages where !rawEnabledPackageIDs.contains(package.id) && hasRuntimeCompanionResources(package) {
            let packageSkillNames = Set(package.skills.map { CapabilityRuntimeResourceMatcher.normalizedName($0.name) })
            guard !packageSkillNames.isDisjoint(with: selectedSkillNames) else { continue }
            checks.append((package, .selectedPackageSkill))
        }

        var seenChecks = Set<String>()
        var issues: [CapabilityRuntimeIntegrityIssue] = []
        for (package, source) in checks where seenChecks.insert("\(source.rawValue):\(package.id)").inserted {
            if source == .enabledPackage,
               let policyContext {
                let decision = CapabilityCatalogPolicy.decision(for: package, context: policyContext)
                if !decision.canRun {
                    issues.append(issue(
                        package: package,
                        source: source,
                        kind: .policy,
                        name: package.name,
                        message: "catalog policy blocks runtime activation: \(decision.blockerMessages.joined(separator: "; "))"
                    ))
                    if shouldReportPolicyDeniedEnabledPackage(decision) {
                        continue
                    }
                }
            }
            issues += resourceIssues(
                package: package,
                source: source,
                reachableSkills: reachableSkills,
                reachableConnectors: reachableConnectors,
                availableConnectors: availableConnectors,
                reachableTools: reachableTools,
                enabledBrowserAdapters: enabledBrowserAdapters,
                prerequisiteStatuses: prerequisiteStatuses,
                checkExecutables: checkExecutables,
                secretStore: secretStore
            )
        }
        return issues
    }

    private static func shouldReportPolicyDeniedEnabledPackage(_ decision: CapabilityCatalogDecision) -> Bool {
        guard !decision.canRun else { return false }
        return decision.blockers.contains { blocker in
            switch blocker {
            case .packPolicyRestricted:
                return false
            default:
                return true
            }
        }
    }

    static func summaryFields(for issues: [CapabilityRuntimeIntegrityIssue]) -> [String: String] {
        [
            "missing_count": String(issues.count),
            "package_names": CapabilityAudit.compactNames(issues.map(\.packageName)),
            "resource_kinds": CapabilityAudit.compactNames(issues.map { $0.resourceKind.rawValue }),
            "resource_names": CapabilityAudit.compactNames(issues.map(\.resourceName)),
            "sources": CapabilityAudit.compactNames(issues.map { $0.source.rawValue })
        ]
    }

    static func userMessage(for issues: [CapabilityRuntimeIntegrityIssue]) -> String {
        let lines = issues.map { issue in
            "- \(issue.packageName): \(issue.message)"
        }
        return """
        ASTRA could not launch because one or more selected capabilities are not fully connected to runtime resources:

        \(lines.joined(separator: "\n"))

        Fix the capability in Manage Capabilities, or disable/exclude it for this task, then retry.
        """
    }

    private static func resourceIssues(
        package: PluginPackage,
        source: CapabilityRuntimeIntegrityIssue.Source,
        reachableSkills: [Skill],
        reachableConnectors: [Connector],
        availableConnectors: [Connector],
        reachableTools: [LocalTool],
        enabledBrowserAdapters: Set<String>,
        prerequisiteStatuses: [String: HealthStatus],
        checkExecutables: Bool,
        secretStore: SecretStore
    ) -> [CapabilityRuntimeIntegrityIssue] {
        var issues: [CapabilityRuntimeIntegrityIssue] = []

        if source == .enabledPackage {
            for pluginSkill in package.skills where !isPackageSkillResolved(
                pluginSkill,
                package: package,
                resolvedSkills: reachableSkills,
                resolvedConnectors: reachableConnectors,
                resolvedTools: reachableTools
            ) {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .skill,
                    name: pluginSkill.name,
                    message: "skill \(pluginSkill.name) is not installed for this workspace"
                ))
            }
        }

        for pluginConnector in package.connectors {
            let matches = reachableConnectors.filter {
                CapabilityRuntimeResourceMatcher.connectorMatches(pluginConnector, connector: $0)
            }
            if matches.isEmpty {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .connector,
                    name: pluginConnector.name,
                    message: inactiveConnectorMessage(
                        for: pluginConnector,
                        availableConnectors: availableConnectors,
                        resolvedConnectors: reachableConnectors
                    )
                ))
                continue
            }

            let credentialGaps = connectorCredentialGaps(
                for: matches,
                secretStore: secretStore
            )
            let hasUsableCredentialSet = matches.contains {
                connectorHasUsableCredentials($0, secretStore: secretStore)
            }
            if !hasUsableCredentialSet {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .credential,
                    name: credentialIssueResourceName(
                        pluginConnector: pluginConnector,
                        gaps: credentialGaps
                    ),
                    message: credentialIssueMessage(
                        pluginConnector: pluginConnector,
                        gaps: credentialGaps
                    )
                ))
            }
        }

        for pluginTool in package.localTools {
            let matches = reachableTools.filter {
                CapabilityRuntimeResourceMatcher.toolMatches(pluginTool, tool: $0)
            }
            if matches.isEmpty {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .localTool,
                    name: pluginTool.name,
                    message: "local tool \(pluginTool.name) is not active for this workspace"
                ))
                continue
            }

            if checkExecutables,
               pluginTool.toolType != "mcp",
               let missingCommand = missingExecutableCommand(for: pluginTool, matches: matches) {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .executable,
                    name: missingCommand,
                    message: "local tool command \(missingCommand) is not installed or not executable"
                ))
            }
        }

        for server in package.mcpServers {
            if checkExecutables,
               server.transport == .stdio {
                let command = (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if command.isEmpty || RuntimePathResolver.detectExecutablePath(named: command).isEmpty {
                    issues.append(issue(
                        package: package,
                        source: source,
                        kind: .mcpServer,
                        name: server.displayName,
                        message: "MCP server \(server.displayName) command \(command.isEmpty ? server.id : command) is not installed or not executable"
                    ))
                }
            }

            if server.transport != .stdio,
               server.url == nil {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .mcpServer,
                    name: server.displayName,
                    message: "MCP server \(server.displayName) is missing a remote URL"
                ))
            }
        }

        for adapter in package.browserAdapters {
            guard let normalized = BrowserSiteAdapterID.normalized(adapter) else {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .browserAdapter,
                    name: adapter,
                    message: "browser adapter \(adapter) is not known to ASTRA"
                ))
                continue
            }
            guard !enabledBrowserAdapters.contains(normalized) else { continue }
            issues.append(issue(
                package: package,
                source: source,
                kind: .browserAdapter,
                name: adapter,
                message: "browser adapter \(adapter) is not active for this workspace"
            ))
        }

        issues += CapabilityHealthService.prerequisiteIssues(
            for: package,
            statuses: prerequisiteStatuses
        ).map { healthIssue in
            issue(
                package: package,
                source: source,
                kind: resourceKind(for: healthIssue),
                name: healthIssue.resourceName,
                message: healthIssue.message
            )
        }

        return issues
    }

    private static func missingExecutableCommand(
        for pluginTool: PluginLocalTool,
        matches: [LocalTool]
    ) -> String? {
        let configuredCommands = matches
            .filter { $0.toolType != "mcp" }
            .map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let packageCommand = pluginTool.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = configuredCommands.isEmpty && !packageCommand.isEmpty
            ? [packageCommand]
            : configuredCommands
        guard !commands.isEmpty else { return nil }

        let missing = commands.filter {
            RuntimePathResolver.detectExecutablePath(named: $0).isEmpty
        }
        guard missing.count == commands.count else { return nil }
        return missing.joined(separator: ", ")
    }

    private struct ConnectorCredentialGap {
        let connector: Connector
        let missingKeys: [String]
        let hasDeclaredKeys: Bool
    }

    private struct ConnectorCredentialRequirements {
        let declaredKeys: [String]
        let missingKeys: [String]
    }

    private static func connectorHasUsableCredentials(
        _ connector: Connector,
        secretStore: SecretStore
    ) -> Bool {
        guard connector.authMethod != "none" else { return true }
        let requirements = connectorCredentialRequirements(for: connector, secretStore: secretStore)
        guard !requirements.declaredKeys.isEmpty else { return false }
        return requirements.missingKeys.isEmpty
    }

    private static func connectorCredentialGaps(
        for connectors: [Connector],
        secretStore: SecretStore
    ) -> [ConnectorCredentialGap] {
        connectors.compactMap { connector in
            guard connector.authMethod != "none" else { return nil }
            let requirements = connectorCredentialRequirements(for: connector, secretStore: secretStore)
            guard !requirements.declaredKeys.isEmpty else {
                return ConnectorCredentialGap(
                    connector: connector,
                    missingKeys: [],
                    hasDeclaredKeys: false
                )
            }
            guard !requirements.missingKeys.isEmpty else { return nil }
            return ConnectorCredentialGap(
                connector: connector,
                missingKeys: requirements.missingKeys,
                hasDeclaredKeys: true
            )
        }
    }

    private static func connectorCredentialRequirements(
        for connector: Connector,
        secretStore: SecretStore
    ) -> ConnectorCredentialRequirements {
        let declaredKeys = normalizedCredentialKeys(for: connector)
        let entityIDs = KeychainSecretStore.connectorEntityIDs(for: connector)
        let missingKeys = declaredKeys.filter { key in
            !entityIDs.contains { entityID in
                let value = secretStore.load(key: key, entityID: entityID)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !value.isEmpty
            }
        }
        return ConnectorCredentialRequirements(
            declaredKeys: declaredKeys,
            missingKeys: missingKeys
        )
    }

    private static func normalizedCredentialKeys(for connector: Connector) -> [String] {
        connector.credentialKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func credentialIssueResourceName(
        pluginConnector: PluginConnector,
        gaps: [ConnectorCredentialGap]
    ) -> String {
        guard gaps.count == 1 else { return pluginConnector.name }
        return connectorDisplayName(gaps[0].connector, fallback: pluginConnector.name)
    }

    private static func credentialIssueMessage(
        pluginConnector: PluginConnector,
        gaps: [ConnectorCredentialGap]
    ) -> String {
        guard !gaps.isEmpty else {
            return "connector \(pluginConnector.name) is missing credentials"
        }
        if gaps.count == 1 {
            let gap = gaps[0]
            let name = connectorDisplayName(gap.connector, fallback: pluginConnector.name)
            guard gap.hasDeclaredKeys else {
                return "connector \(name) has no credentials configured"
            }
            return "connector \(name) is missing Keychain value: \(gap.missingKeys.joined(separator: ", "))"
        }

        let names = CapabilityAudit.compactNames(
            gaps.map { connectorDisplayName($0.connector, fallback: pluginConnector.name) }
        )
        let missing = Set(gaps.flatMap(\.missingKeys)).sorted()
        if missing.isEmpty {
            return "matching connectors \(names) have no credentials configured"
        }
        return "matching connectors \(names) are missing Keychain values: \(missing.joined(separator: ", "))"
    }

    private static func connectorDisplayName(
        _ connector: Connector,
        fallback: String
    ) -> String {
        let name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func resourceKind(
        for issue: CapabilityHealthIssue
    ) -> CapabilityRuntimeIntegrityIssue.ResourceKind {
        switch issue.kind {
        case .missingBinary:
            return .executable
        case .unauthenticated:
            return .credential
        case .unresponsive:
            return .localTool
        }
    }

    private static func isPackageSkillResolved(
        _ pluginSkill: PluginSkill,
        package: PluginPackage,
        resolvedSkills: [Skill],
        resolvedConnectors: [Connector],
        resolvedTools: [LocalTool]
    ) -> Bool {
        if resolvedSkills.contains(where: { CapabilityRuntimeResourceMatcher.skillMatches(pluginSkill, skill: $0) }) {
            return true
        }

        guard package.skills.count == 1 else { return false }
        let resolvedSkillIDs = Set(resolvedSkills.map(\.id))
        return companionSkills(
            for: package,
            resolvedConnectors: resolvedConnectors,
            resolvedTools: resolvedTools
        )
        .contains { resolvedSkillIDs.contains($0.id) }
    }

    private static func companionSkills(
        for package: PluginPackage,
        resolvedConnectors: [Connector],
        resolvedTools: [LocalTool]
    ) -> [Skill] {
        let connectorSkills = package.connectors.flatMap { pluginConnector in
            resolvedConnectors
                .filter { CapabilityRuntimeResourceMatcher.connectorMatches(pluginConnector, connector: $0) }
                .compactMap(\.skill)
        }
        let toolSkills = package.localTools.flatMap { pluginTool in
            resolvedTools
                .filter { CapabilityRuntimeResourceMatcher.toolMatches(pluginTool, tool: $0) }
                .compactMap(\.skill)
        }

        var seen = Set<UUID>()
        return (connectorSkills + toolSkills).filter { seen.insert($0.id).inserted }
    }

    private static func availableConnectors(for task: AgentTask) -> [Connector] {
        var connectors = task.workspace?.connectors ?? []
        if let ctx = task.modelContext {
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
            connectors += (try? ctx.fetch(descriptor)) ?? []
        }
        return uniqueConnectors(connectors)
    }

    private static func inactiveConnectorMessage(
        for pluginConnector: PluginConnector,
        availableConnectors: [Connector],
        resolvedConnectors: [Connector]
    ) -> String {
        let resolvedIDs = Set(resolvedConnectors.map(\.id))
        let inactiveMatches = availableConnectors.filter { connector in
            CapabilityRuntimeResourceMatcher.connectorMatches(pluginConnector, connector: connector)
                && !resolvedIDs.contains(connector.id)
        }

        guard let connector = inactiveMatches.first else {
            return "connector \(pluginConnector.name) is not configured or enabled for this workspace"
        }

        let displayName = connector.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? pluginConnector.name
            : connector.name
        if connector.isGlobal {
            return "shared connector \(displayName) is configured but disabled in this workspace; enable it in Connectors > Sharing or from the Shared Library list"
        }
        return "connector \(displayName) is configured but not active for this workspace"
    }

    private static func shouldCheckEnabledPackage(
        _ package: PluginPackage,
        task: AgentTask,
        scope: TaskCapabilityResolutionScope,
        resolvedSkills: [Skill],
        resolvedConnectors: [Connector],
        resolvedTools: [LocalTool]
    ) -> Bool {
        guard scope.isProviderLaunch else { return true }

        if packageHasScopedRuntimeResource(
            package,
            resolvedSkills: resolvedSkills,
            resolvedConnectors: resolvedConnectors,
            resolvedTools: resolvedTools
        ) {
            return true
        }

        return packageMatchesTaskIntent(package, task: task, contextText: scope.contextText)
    }

    private static func packageHasScopedRuntimeResource(
        _ package: PluginPackage,
        resolvedSkills: [Skill],
        resolvedConnectors: [Connector],
        resolvedTools: [LocalTool]
    ) -> Bool {
        if package.skills.contains(where: { pluginSkill in
            resolvedSkills.contains { CapabilityRuntimeResourceMatcher.skillMatches(pluginSkill, skill: $0) }
        }) {
            return true
        }

        if package.connectors.contains(where: { pluginConnector in
            resolvedConnectors.contains { CapabilityRuntimeResourceMatcher.connectorMatches(pluginConnector, connector: $0) }
        }) {
            return true
        }

        return package.localTools.contains { pluginTool in
            resolvedTools.contains { CapabilityRuntimeResourceMatcher.toolMatches(pluginTool, tool: $0) }
        }
    }

    private static func packageMatchesTaskIntent(
        _ package: PluginPackage,
        task: AgentTask,
        contextText: String
    ) -> Bool {
        let taskText = TaskContextStateManager.capabilitySearchText(
            for: task,
            contextText: contextText
        )
        let taskTokens = searchTokens(taskText)
        guard !taskTokens.isEmpty else { return false }

        let packageText = [
            package.id,
            package.name,
            package.description,
            package.category,
            package.tags.joined(separator: " "),
            package.skills.map { "\($0.name) \($0.description) \($0.behaviorInstructions)" }.joined(separator: " "),
            package.connectors.map { "\($0.name) \($0.serviceType) \($0.description) \($0.baseURL)" }.joined(separator: " "),
            package.localTools.map { "\($0.name) \($0.command) \($0.description)" }.joined(separator: " "),
            package.mcpServers.map { "\($0.id) \($0.displayName) \($0.command ?? "") \($0.url?.absoluteString ?? "")" }.joined(separator: " "),
            package.browserAdapters.joined(separator: " ")
        ].joined(separator: " ")
        let packageTokens = searchTokens(packageText)
        guard !packageTokens.isEmpty else { return false }

        return !taskTokens.isDisjoint(with: packageTokens)
    }

    private static func searchTokens(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        for token in normalizedSearchText(text).split(separator: " ").map(String.init) {
            guard token.count >= 3, !genericIntentTokens.contains(token) else { continue }
            tokens.insert(token)
            if token.count > 4, token.hasSuffix("s") {
                tokens.insert(String(token.dropLast()))
            }
        }
        return tokens
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func liveSelectedPackageSkillNames(
        for task: AgentTask,
        resolvedSkills: [Skill],
        scope: TaskCapabilityResolutionScope
    ) -> Set<String> {
        // Snapshots are durable history for prompt reconstruction. They can outlive
        // the user's current capability selection, so only live task skills should
        // trigger selected-package launch blockers.
        let skills = scope.isProviderLaunch ? resolvedSkills : task.skills
        return Set(
            skills.map(\.name)
                .map(CapabilityRuntimeResourceMatcher.normalizedName)
                .filter { !$0.isEmpty }
        )
    }

    private static func hasRuntimeCompanionResources(_ package: PluginPackage) -> Bool {
        !package.connectors.isEmpty
            || !package.localTools.isEmpty
            || !package.mcpServers.isEmpty
            || !package.browserAdapters.isEmpty
            || HostControlPlaneMCPProjection.packageUsesHostControlRuntime(package)
    }

    private static let genericIntentTokens: Set<String> = [
        "agent",
        "and",
        "api",
        "app",
        "after",
        "are",
        "before",
        "can",
        "browser",
        "capability",
        "check",
        "cloud",
        "code",
        "connector",
        "content",
        "create",
        "current",
        "data",
        "delete",
        "deliver",
        "develop",
        "demo",
        "doc",
        "document",
        "docker",
        "download",
        "file",
        "files",
        "for",
        "forward",
        "from",
        "generate",
        "get",
        "html",
        "implement",
        "inspect",
        "javascript",
        "list",
        "local",
        "look",
        "manage",
        "make",
        "must",
        "only",
        "open",
        "page",
        "plugin",
        "produce",
        "prototype",
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
        "site",
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
        "webpage",
        "website",
        "when",
        "with",
        "work",
        "workflow",
        "workspace",
        "write"
    ]

    private static func issue(
        package: PluginPackage,
        source: CapabilityRuntimeIntegrityIssue.Source,
        kind: CapabilityRuntimeIntegrityIssue.ResourceKind,
        name: String,
        message: String
    ) -> CapabilityRuntimeIntegrityIssue {
        CapabilityRuntimeIntegrityIssue(
            packageID: package.id,
            packageName: package.name,
            source: source,
            resourceKind: kind,
            resourceName: name,
            message: message
        )
    }

    private static func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return connectors.filter { seen.insert($0.id).inserted }
    }
}
