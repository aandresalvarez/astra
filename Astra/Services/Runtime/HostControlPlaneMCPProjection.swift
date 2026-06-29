import Foundation
import ASTRACore

enum HostControlPlaneMCPProjection {
    static let serverID = "astra_host"
    static let toolNames = ["github", "gcloud", "bq", "ssh", "jira"]

    static func isEnabled(for environment: WorkspaceExecutionEnvironment) -> Bool {
        DockerWorkspaceMCPProjection.isEnabled(for: environment)
    }

    static func supportsHostControlPlane(runtime: AgentRuntimeID) -> Bool {
        AgentRuntimeAdapterRegistry.descriptor(for: runtime).supportsMCPServers
    }

    static func runtimeSupportToolDescriptors(for runtime: AgentRuntimeID) -> [ProviderRuntimeSupportToolDescriptor] {
        guard supportsHostControlPlane(runtime: runtime) else { return [] }
        return toolNames.map { tool in
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
        RunPermissionManifest.MCPServer(
            id: serverID,
            packageID: "astra-builtin",
            displayName: "ASTRA Host Control Plane",
            transport: PluginMCPServer.Transport.stdio.rawValue,
            allowedTools: toolNames,
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
        taskEnvironment: [String: String] = [:]
    ) -> MCPRuntimeProjection.ResolvedServer? {
        guard isEnabled(for: environment) else { return nil }
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
                allowedTools: toolNames,
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
        taskEnvironment: [String: String] = [:]
    ) -> [String: String] {
        guard isEnabled(for: environment) else { return [:] }
        var output: [String: String] = [
            "ASTRA_HOST_CONTROL_GH_EXECUTABLE": detectExecutable("gh"),
            "ASTRA_HOST_CONTROL_GCLOUD_EXECUTABLE": detectExecutable("gcloud"),
            "ASTRA_HOST_CONTROL_BQ_EXECUTABLE": detectExecutable("bq"),
            "ASTRA_HOST_CONTROL_SSH_EXECUTABLE": detectExecutable("ssh", fallback: "/usr/bin/ssh"),
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
            return "Run BigQuery control-plane commands on the host through ASTRA without provider Bash."
        case "ssh":
            return "Run configured workspace SSH aliases on the host through ASTRA without provider Bash."
        case "jira":
            return "Use ASTRA-projected Jira connector credentials through the host control-plane bridge."
        default:
            return "Use ASTRA's host control-plane bridge."
        }
    }

    private static func allowedInputKeys(for tool: String) -> [String] {
        switch tool {
        case "github", "gcloud", "bq":
            return ["arguments", "timeout_seconds"]
        case "ssh":
            return ["alias", "remote_command", "timeout_seconds"]
        case "jira":
            return ["operation", "alias", "method", "path", "body", "timeout_seconds"]
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
