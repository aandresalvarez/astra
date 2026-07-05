import Foundation
import ASTRACore

enum HostControlPlaneMCPProjection {
    static let serverID = "astra_host"
    static let toolNames = ["github", "gcloud", "bq", "ssh", "jira"]
    static let githubPackageID = "github-workflow"

    static func isEnabled(for environment: WorkspaceExecutionEnvironment) -> Bool {
        DockerWorkspaceMCPProjection.isEnabled(for: environment)
    }

    static func enabledToolNames(
        task: AgentTask,
        environment: WorkspaceExecutionEnvironment,
        contextText: String = "",
        capabilityScope: TaskCapabilityPromptScope? = nil
    ) -> [String] {
        if isEnabled(for: environment) {
            return toolNames
        }
        let scope = capabilityScope ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        return requiredToolNames(capabilityScope: scope)
    }

    static func requiredToolNames(capabilityScope: TaskCapabilityPromptScope) -> [String] {
        var required = Set<String>()
        if githubCapabilityIsInScope(capabilityScope) {
            required.insert("github")
        }
        for snapshot in capabilityScope.resolver.effectiveSnapshots {
            required.formUnion(requiredToolNames(inBehaviorText: snapshot.behaviorInstructions))
        }
        return orderedToolNames(required)
    }

    static func requiresNativeShellDenial(
        task: AgentTask,
        environment: WorkspaceExecutionEnvironment,
        contextText: String = ""
    ) -> Bool {
        !enabledToolNames(task: task, environment: environment, contextText: contextText).isEmpty
    }

    static func packageUsesHostControlRuntime(_ package: PluginPackage) -> Bool {
        if package.id == githubPackageID {
            return true
        }
        return package.skills.contains { skill in
            !requiredToolNames(inBehaviorText: skill.behaviorInstructions).isEmpty
        }
    }

    static func supportsHostControlPlane(runtime: AgentRuntimeID, executablePath: String = "") -> Bool {
        AgentRuntimeCapabilityProfileService
            .profile(for: runtime, executablePath: executablePath)
            .canDeliverHostControlPlaneMCP
    }

    static func runtimeSupportToolDescriptors(for runtime: AgentRuntimeID) -> [ProviderRuntimeSupportToolDescriptor] {
        runtimeSupportToolDescriptors(for: runtime, tools: toolNames)
    }

    static func runtimeSupportToolDescriptors(
        for runtime: AgentRuntimeID,
        tools requestedTools: [String]
    ) -> [ProviderRuntimeSupportToolDescriptor] {
        guard supportsHostControlPlane(runtime: runtime) else { return [] }
        return runtimeSupportToolDescriptors(tools: requestedTools)
    }

    static func runtimeSupportToolDescriptors(
        runtimeProfile: AgentRuntimeCapabilityProfile,
        tools requestedTools: [String]
    ) -> [ProviderRuntimeSupportToolDescriptor] {
        guard runtimeProfile.canDeliverHostControlPlaneMCP else { return [] }
        return runtimeSupportToolDescriptors(tools: requestedTools)
    }

    private static func runtimeSupportToolDescriptors(
        tools requestedTools: [String]
    ) -> [ProviderRuntimeSupportToolDescriptor] {
        let requested = requestedTools.filter { toolNames.contains($0) }
        return requested.map { tool in
            ProviderRuntimeSupportToolDescriptor(
                name: providerToolPermission(for: tool),
                purpose: runtimeSupportPurpose(for: tool),
                allowedInputKeys: allowedInputKeys(for: tool),
                deniedInputKeys: deniedInputKeys(for: tool),
                maxSummaryLength: 2_000
            )
        }
    }

    static func manifestServer() -> RunPermissionManifest.MCPServer {
        manifestServer(allowedTools: toolNames)
    }

    static func manifestServer(allowedTools requestedTools: [String]) -> RunPermissionManifest.MCPServer {
        let allowedTools = requestedTools.filter { toolNames.contains($0) }
        return RunPermissionManifest.MCPServer(
            id: serverID,
            packageID: "astra-builtin",
            displayName: "ASTRA Host Control Plane",
            transport: PluginMCPServer.Transport.stdio.rawValue,
            allowedTools: allowedTools,
            excludedTools: [],
            resourcesEnabled: false,
            promptsEnabled: false,
            trustLevel: PluginMCPServer.TrustLevel.high.rawValue
        )
    }

    static func resolvedServer(
        task: AgentTask,
        environment: WorkspaceExecutionEnvironment,
        currentDirectory: String,
        runID: UUID?,
        taskEnvironment: [String: String] = [:],
        contextText: String = "",
        capabilityScope: TaskCapabilityPromptScope? = nil
    ) -> MCPRuntimeProjection.ResolvedServer? {
        let allowedTools = enabledToolNames(
            task: task,
            environment: environment,
            contextText: contextText,
            capabilityScope: capabilityScope
        )
        guard !allowedTools.isEmpty else { return nil }
        let envKeys = environmentKeys(taskEnvironment: taskEnvironment)
        return MCPRuntimeProjection.ResolvedServer(
            packageID: "astra-builtin",
            server: PluginMCPServer(
                id: serverID,
                displayName: "ASTRA Host Control Plane",
                transport: .stdio,
                command: astraHostControlToolPath(),
                arguments: [],
                environmentKeys: envKeys,
                allowedTools: allowedTools,
                trustLevel: .high
            ),
            permittedEnvironmentKeys: Set(envKeys)
        )
    }

    static func environmentVariables(
        task: AgentTask,
        environment: WorkspaceExecutionEnvironment,
        currentDirectory: String,
        runID: UUID?,
        taskEnvironment: [String: String] = [:],
        contextText: String = "",
        capabilityScope: TaskCapabilityPromptScope? = nil
    ) -> [String: String] {
        let allowedTools = enabledToolNames(
            task: task,
            environment: environment,
            contextText: contextText,
            capabilityScope: capabilityScope
        )
        guard !allowedTools.isEmpty else { return [:] }
        var output: [String: String] = [
            "ASTRA_HOST_CONTROL_GH_EXECUTABLE": detectExecutable("gh"),
            "ASTRA_HOST_CONTROL_GCLOUD_EXECUTABLE": detectExecutable("gcloud"),
            "ASTRA_HOST_CONTROL_BQ_EXECUTABLE": detectExecutable("bq"),
            "ASTRA_HOST_CONTROL_SSH_EXECUTABLE": detectExecutable("ssh", fallback: "/usr/bin/ssh"),
            "ASTRA_HOST_CONTROL_ALLOWED_TOOLS": allowedTools.joined(separator: ","),
            "ASTRA_HOST_CONTROL_CURRENT_DIRECTORY": currentDirectory,
            "ASTRA_HOST_CONTROL_TASK_ID": task.id.uuidString,
            "ASTRA_HOST_CONTROL_RUN_ID": runID?.uuidString ?? "run",
            "ASTRA_HOST_CONTROL_DIAGNOSTICS_HOST": diagnosticsHostPath(task: task),
            "ASTRA_HOST_CONTROL_ALLOWED_SSH_ALIASES": allowedSSHAliases(task: task).joined(separator: ",")
        ]
        for (key, value) in taskEnvironment where connectorEnvironmentKey(key) {
            output[key] = value
        }
        return output
    }

    static func providerToolPermission(for tool: String) -> String {
        "mcp__\(serverID)__\(tool)"
    }

    static func canonicalToolName(fromObservedToolName observedToolName: String, runtime: AgentRuntimeID) -> String? {
        let normalized = observedToolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for tool in toolNames {
            let commonNames: Set<String> = [
                providerToolPermission(for: tool).lowercased(),
                "\(serverID).\(tool)".lowercased(),
                "\(serverID)/\(tool)".lowercased(),
                tool.lowercased()
            ]
            if commonNames.contains(normalized) {
                return tool
            }
            if runtime == .copilotCLI,
               normalized == copilotObservedToolName(for: tool).lowercased()
                    || normalized == copilotPermissionPattern(for: tool).lowercased() {
                return tool
            }
        }
        return nil
    }

    static func copilotObservedToolName(for tool: String) -> String {
        "\(serverID)-\(tool)"
    }

    static func copilotPermissionPattern(for tool: String) -> String {
        "\(serverID)(\(tool))"
    }

    private static let baseEnvironmentKeys = [
        "ASTRA_HOST_CONTROL_GH_EXECUTABLE",
        "ASTRA_HOST_CONTROL_GCLOUD_EXECUTABLE",
        "ASTRA_HOST_CONTROL_BQ_EXECUTABLE",
        "ASTRA_HOST_CONTROL_SSH_EXECUTABLE",
        "ASTRA_HOST_CONTROL_ALLOWED_SSH_ALIASES",
        "ASTRA_HOST_CONTROL_ALLOWED_TOOLS",
        "ASTRA_HOST_CONTROL_CURRENT_DIRECTORY",
        "ASTRA_HOST_CONTROL_DIAGNOSTICS_HOST",
        "ASTRA_HOST_CONTROL_TASK_ID",
        "ASTRA_HOST_CONTROL_RUN_ID",
        "ASTRA_CONNECTORS"
    ]

    private static func environmentKeys(taskEnvironment: [String: String]) -> [String] {
        let connectorKeys = taskEnvironment.keys.filter(connectorEnvironmentKey)
        return Array(Set(baseEnvironmentKeys + connectorKeys)).sorted()
    }

    private static func connectorEnvironmentKey(_ key: String) -> Bool {
        key == "ASTRA_CONNECTORS"
            || key.range(of: #"^[A-Z][A-Z0-9_]*_[A-Z0-9_]+$"#, options: .regularExpression) != nil
    }

    private static func runtimeSupportPurpose(for tool: String) -> String {
        switch tool {
        case "github":
            return "Run GitHub control-plane commands on the host through ASTRA without provider Bash."
        case "gcloud":
            return "Run read-only Google Cloud control-plane commands on the host through ASTRA without provider Bash."
        case "bq":
            return "Run BigQuery CLI help/version commands on the host through ASTRA without provider Bash."
        case "ssh":
            return "Use configured workspace SSH aliases on the host through ASTRA without accepting provider-supplied remote commands."
        case "jira":
            return "Use typed, read-only Jira connector operations through ASTRA's host control-plane bridge."
        default:
            return "Use ASTRA's host control-plane bridge."
        }
    }

    private static func allowedInputKeys(for tool: String) -> [String] {
        switch tool {
        case "github", "gcloud", "bq":
            return ["arguments", "timeout_seconds"]
        case "ssh":
            return ["alias", "timeout_seconds"]
        case "jira":
            return ["operation", "alias", "issue_key", "jql", "max_results", "next_page_token", "timeout_seconds"]
        default:
            return []
        }
    }

    private static func deniedInputKeys(for tool: String) -> [String] {
        let allowed = Set(allowedInputKeys(for: tool) + ["cmd"])
        return ProviderRuntimeSupportToolDescriptor.defaultDeniedActionInputKeys.filter {
            !allowed.contains($0)
        }
    }

    private static func requiredToolNames(inBehaviorText text: String) -> [String] {
        var required = Set<String>()
        for chunk in hostControlRequirementChunks(text) {
            guard chunkDeclaresRequiredHostControl(chunk) else { continue }
            for tool in toolNames where chunkMentionsHostControlTool(chunk, tool: tool) {
                required.insert(tool)
            }
        }
        return orderedToolNames(required)
    }

    private static func hostControlRequirementChunks(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized
            .components(separatedBy: "\n\n")
            + normalized.components(separatedBy: .newlines)
    }

    private static func chunkDeclaresRequiredHostControl(_ chunk: String) -> Bool {
        let lower = chunk.lowercased()
        guard lower.contains("host-control") || lower.contains("host control") else { return false }
        if lower.contains("docker"),
           !lower.contains("non-docker"),
           !lower.contains("always"),
           !lower.contains("must") {
            return false
        }
        return lower.contains("always use")
            || lower.contains("must use")
            || lower.contains("required")
            || lower.contains("do not use bash")
            || lower.contains("do not use shell")
            || lower.contains("do not use direct")
            || lower.contains("do not use native")
            || lower.contains("bypass this broker")
            || lower.contains("never use")
            || (lower.contains("use astra") && lower.contains(" mcp tool"))
    }

    private static func chunkMentionsHostControlTool(_ chunk: String, tool: String) -> Bool {
        let lower = chunk.lowercased()
        return lower.contains(providerToolPermission(for: tool).lowercased())
            || lower.contains(copilotObservedToolName(for: tool).lowercased())
            || lower.contains("\(serverID).\(tool)".lowercased())
            || lower.contains("\(serverID)/\(tool)".lowercased())
    }

    private static func orderedToolNames(_ required: Set<String>) -> [String] {
        toolNames.filter { required.contains($0) }
    }

    private static func githubCapabilityIsInScope(_ scope: TaskCapabilityPromptScope) -> Bool {
        if scope.enabledPackageIDs.contains(githubPackageID) {
            return true
        }
        return scope.behaviorSkills.contains { skill in
            if skill.originPackageID == githubPackageID {
                return true
            }
            return false
        }
    }

    private static func allowedSSHAliases(task: AgentTask) -> [String] {
        guard let workspace = task.workspace else { return [] }
        let values = SSHConnectionManager.load(workspacePath: workspace.primaryPath).flatMap { connection in
            [
                clean(connection.configAlias),
                clean(connection.name),
                clean(connection.sshTarget)
            ].compactMap { $0 }
        }
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func diagnosticsHostPath(task: AgentTask) -> String {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskFolder.isEmpty else { return "" }
        return (taskFolder as NSString).appendingPathComponent("diagnostics")
    }

    private static func detectExecutable(_ name: String, fallback: String? = nil) -> String {
        RuntimePathResolver.detectExecutablePath(named: name, fallback: fallback ?? name)
    }

    private static func astraHostControlToolPath() -> String {
        (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent("astra-host-control")
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
