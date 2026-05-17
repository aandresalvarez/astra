import Foundation
import SwiftData
import ASTRACore

struct CapabilityRuntimeIntegrityIssue: Equatable, Identifiable {
    enum Source: String {
        case enabledPackage = "enabled_package"
        case selectedPackageSkill = "selected_package_skill"
    }

    enum ResourceKind: String {
        case skill
        case connector
        case localTool = "local_tool"
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
        checkExecutables: Bool = true
    ) -> [CapabilityRuntimeIntegrityIssue] {
        guard let workspace = task.workspace else { return [] }

        let packages = suppliedPackages ?? CapabilityRuntimeResourceMatcher.packageDefinitions()
        let enabledPackageIDs = Set(workspace.enabledCapabilityIDs)
        let selectedSkillNames = selectedPackageSkillNames(for: task)
        let resolver = TaskCapabilityResolver(task: task)
        let resolvedSkills = resolver.allBehaviorSkills
        let resolvedConnectors = resolver.allConnectors
        let resolvedTools = resolver.allLocalTools
        let enabledBrowserAdapters = Set(resolver.enabledBrowserAdapters)
        let availableConnectors = availableConnectors(for: task)

        var checks: [(PluginPackage, CapabilityRuntimeIntegrityIssue.Source)] = []
        for package in packages where enabledPackageIDs.contains(package.id) {
            checks.append((package, .enabledPackage))
        }

        for package in packages where !enabledPackageIDs.contains(package.id) && hasRuntimeCompanionResources(package) {
            let packageSkillNames = Set(package.skills.map { CapabilityRuntimeResourceMatcher.normalizedName($0.name) })
            guard !packageSkillNames.isDisjoint(with: selectedSkillNames) else { continue }
            checks.append((package, .selectedPackageSkill))
        }

        var seenChecks = Set<String>()
        var issues: [CapabilityRuntimeIntegrityIssue] = []
        for (package, source) in checks where seenChecks.insert("\(source.rawValue):\(package.id)").inserted {
            issues += resourceIssues(
                package: package,
                source: source,
                resolvedSkills: resolvedSkills,
                resolvedConnectors: resolvedConnectors,
                availableConnectors: availableConnectors,
                resolvedTools: resolvedTools,
                enabledBrowserAdapters: enabledBrowserAdapters,
                checkExecutables: checkExecutables
            )
        }
        return issues
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
        resolvedSkills: [Skill],
        resolvedConnectors: [Connector],
        availableConnectors: [Connector],
        resolvedTools: [LocalTool],
        enabledBrowserAdapters: Set<String>,
        checkExecutables: Bool
    ) -> [CapabilityRuntimeIntegrityIssue] {
        var issues: [CapabilityRuntimeIntegrityIssue] = []

        if source == .enabledPackage {
            for pluginSkill in package.skills where !isPackageSkillResolved(
                pluginSkill,
                package: package,
                resolvedSkills: resolvedSkills,
                resolvedConnectors: resolvedConnectors,
                resolvedTools: resolvedTools
            ) {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .skill,
                    name: pluginSkill.name,
                    message: "skill \(pluginSkill.name) is not active for this task"
                ))
            }
        }

        for pluginConnector in package.connectors {
            let matches = resolvedConnectors.filter {
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
                        resolvedConnectors: resolvedConnectors
                    )
                ))
                continue
            }

            let hasUsableCredentialSet = matches.contains { connector in
                connector.authMethod == "none" || connector.missingCredentialKeys().isEmpty
            }
            if !hasUsableCredentialSet {
                let missing = Set(matches.flatMap { $0.missingCredentialKeys() }).sorted()
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .credential,
                    name: pluginConnector.name,
                    message: "connector \(pluginConnector.name) is missing \(missing.joined(separator: ", "))"
                ))
            }
        }

        for pluginTool in package.localTools {
            let matches = resolvedTools.filter {
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
               !pluginTool.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               RuntimePathResolver.detectExecutablePath(named: pluginTool.command).isEmpty {
                issues.append(issue(
                    package: package,
                    source: source,
                    kind: .executable,
                    name: pluginTool.command,
                    message: "local tool command \(pluginTool.command) is not installed or not executable"
                ))
            }
        }

        for adapter in package.browserAdapters {
            guard let normalized = BrowserSiteAdapterID.normalized(adapter),
                  !enabledBrowserAdapters.contains(normalized) else { continue }
            issues.append(issue(
                package: package,
                source: source,
                kind: .browserAdapter,
                name: adapter,
                message: "browser adapter \(adapter) is not active for this workspace"
            ))
        }

        return issues
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

    private static func selectedPackageSkillNames(for task: AgentTask) -> Set<String> {
        Set(
            (task.skills.map(\.name) + task.skillSnapshots.map(\.name))
                .map(CapabilityRuntimeResourceMatcher.normalizedName)
                .filter { !$0.isEmpty }
        )
    }

    private static func hasRuntimeCompanionResources(_ package: PluginPackage) -> Bool {
        !package.connectors.isEmpty || !package.localTools.isEmpty || !package.browserAdapters.isEmpty
    }

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
