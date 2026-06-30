import Foundation
import ASTRACore

struct CopilotMCPLaunchProjection {
    let servers: [MCPRuntimeProjection.ResolvedServer]
    let configURL: URL?
    let allowedTools: [String]
    let workspaceExecutorEnvironment: [String: String]
    let hostControlEnvironment: [String: String]
    let dockerWorkspaceExecutorSupported: Bool
    let dockerWorkspaceUnsupportedDetail: String
    let hostControlPlaneSupported: Bool
    let hostControlPlaneUnsupportedDetail: String
    let hostControlPlaneLaunchBlockReason: String
    let browserBridgeMCPToolSupported: Bool

    var readablePaths: [String] {
        configURL.map { [$0.deletingLastPathComponent().path] } ?? []
    }

    static func resolve(
        task: AgentTask,
        workspacePath: String,
        runID: UUID?,
        executionEnvironment: WorkspaceExecutionEnvironment,
        contextText: String,
        taskEnvironment: [String: String] = [:],
        capabilities: CopilotCLICapabilities
    ) -> CopilotMCPLaunchProjection {
        let usesDockerWorkspaceExecutor = DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)
        var browserServerProjected = false
        var servers: [MCPRuntimeProjection.ResolvedServer] = []
        if capabilities.supportsAdditionalMCPConfig {
            servers = MCPRuntimeProjection.enabledServers(
                for: task.workspace,
                packages: CapabilityRuntimeResourceMatcher.packageDefinitions(),
                approvalRecords: CapabilityApprovalStore().records()
            )
            if let workspaceServer = DockerWorkspaceMCPProjection.resolvedServer(
                task: task,
                environment: executionEnvironment,
                currentDirectory: workspacePath,
                runID: runID
            ) {
                servers.append(workspaceServer)
            }
            let hostControlEnvironment = HostControlPlaneMCPProjection.environmentVariables(
                task: task,
                environment: executionEnvironment,
                currentDirectory: workspacePath,
                runID: runID,
                taskEnvironment: taskEnvironment,
                contextText: contextText
            )
            if let hostControlServer = HostControlPlaneMCPProjection.resolvedServer(
                task: task,
                environment: executionEnvironment,
                currentDirectory: workspacePath,
                runID: runID,
                taskEnvironment: taskEnvironment.merging(hostControlEnvironment) { current, _ in current },
                contextText: contextText
            ) {
                servers.append(hostControlServer)
            }
            if let browserServer = BrowserBridgeMCPProjection.resolvedServer(
                for: task,
                contextText: contextText
            ) {
                servers.append(browserServer)
                browserServerProjected = true
            }
        }

        let workspaceExecutorEnvironment = DockerWorkspaceMCPProjection.environmentVariables(
            task: task,
            environment: executionEnvironment,
            currentDirectory: workspacePath,
            runID: runID
        )
        let hostControlEnvironment = HostControlPlaneMCPProjection.environmentVariables(
            task: task,
            environment: executionEnvironment,
            currentDirectory: workspacePath,
            runID: runID,
            taskEnvironment: taskEnvironment,
            contextText: contextText
        )
        let explicitMCPEnvironment = taskEnvironment
            .merging(workspaceExecutorEnvironment) { current, _ in current }
            .merging(hostControlEnvironment) { current, _ in current }
        let configURL = servers.isEmpty
            ? nil
            : MCPRuntimeProjection.writeClaudeConfig(
                servers: servers,
                taskID: task.id,
                availableEnvironment: explicitMCPEnvironment
            )
        let dockerWorkspaceExecutorSupported = !usesDockerWorkspaceExecutor
            || (capabilities.supportsAdditionalMCPConfig && configURL != nil)
        let requiresHostControlPlane = !hostControlEnvironment.isEmpty
        let hostControlPlaneSupported = !requiresHostControlPlane
            || (capabilities.supportsAdditionalMCPConfig && configURL != nil)
        let unsupportedDetail = unsupportedDockerWorkspaceDetail(
            usesDockerWorkspaceExecutor: usesDockerWorkspaceExecutor,
            supportsAdditionalMCPConfig: capabilities.supportsAdditionalMCPConfig,
            configURL: configURL
        )
        let hostControlUnsupportedDetail = unsupportedHostControlPlaneDetail(
            requiresHostControlPlane: requiresHostControlPlane,
            supportsAdditionalMCPConfig: capabilities.supportsAdditionalMCPConfig,
            configURL: configURL
        )
        let hostControlLaunchBlockReason = hostControlPlaneSupported
            ? "none"
            : HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason

        return CopilotMCPLaunchProjection(
            servers: servers,
            configURL: configURL,
            allowedTools: configURL == nil ? [] : MCPRuntimeProjection.allowedToolPermissions(
                servers: servers,
                availableEnvironment: explicitMCPEnvironment
            ),
            workspaceExecutorEnvironment: workspaceExecutorEnvironment,
            hostControlEnvironment: hostControlEnvironment,
            dockerWorkspaceExecutorSupported: dockerWorkspaceExecutorSupported,
            dockerWorkspaceUnsupportedDetail: unsupportedDetail,
            hostControlPlaneSupported: hostControlPlaneSupported,
            hostControlPlaneUnsupportedDetail: hostControlUnsupportedDetail,
            hostControlPlaneLaunchBlockReason: hostControlLaunchBlockReason,
            browserBridgeMCPToolSupported: browserServerProjected && configURL != nil
        )
    }

    private static func unsupportedDockerWorkspaceDetail(
        usesDockerWorkspaceExecutor: Bool,
        supportsAdditionalMCPConfig: Bool,
        configURL: URL?
    ) -> String {
        if !usesDockerWorkspaceExecutor { return "" }
        if !supportsAdditionalMCPConfig {
            return "GitHub Copilot CLI does not support --additional-mcp-config, so ASTRA cannot attach the Docker workspace shell MCP server."
        }
        if configURL == nil {
            return "ASTRA could not render the Docker workspace shell MCP config for GitHub Copilot CLI."
        }
        return ""
    }

    private static func unsupportedHostControlPlaneDetail(
        requiresHostControlPlane: Bool,
        supportsAdditionalMCPConfig: Bool,
        configURL: URL?
    ) -> String {
        if !requiresHostControlPlane { return "" }
        if !supportsAdditionalMCPConfig {
            return "GitHub Copilot CLI does not support --additional-mcp-config, so ASTRA cannot attach the host-control GitHub MCP server."
        }
        if configURL == nil {
            return "ASTRA could not render the host-control MCP config for GitHub Copilot CLI."
        }
        return ""
    }
}

enum HostControlPlaneRuntimeLaunchGuard {
    static let missingHostControlMCPReason = "host_control_plane_unsupported_runtime"

    static func launchBlock(for plan: AgentRuntimeProcessLaunchPlan) -> AgentProcessResult? {
        guard plan.commandPlannedFields["host_control_plane_launch_block_reason"] == missingHostControlMCPReason else {
            return nil
        }

        let detail = plan.commandPlannedFields["host_control_plane_unsupported_detail"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail?.isEmpty == false
            ? detail!
            : "\(plan.runtime.displayName) cannot attach ASTRA's host-control MCP server for this task. Switch to a runtime that supports provider MCP config, then retry."
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: missingHostControlMCPReason,
            runtimeStopMessage: message
        )
    }
}

enum CopilotLaunchDiagnostics {
    static func providerDetectedFields(
        id: AgentRuntimeID,
        providerVersion: String?,
        executable: String,
        executableConfigured: Bool
    ) -> [String: String] {
        [
            "runtime": id.rawValue,
            "provider_version": providerVersion ?? "unknown",
            "executable_configured": String(executableConfigured),
            "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
            "executable_path": executable,
            "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(executable)
        ]
    }

    static func commandPlannedFields(
        id: AgentRuntimeID,
        phase: String,
        model: String,
        plan: CopilotCLICommandPlan,
        capabilities: CopilotCLICapabilities,
        effectivePermissionPolicy: PermissionPolicy,
        providerAllowed: [String],
        baseProviderAllowed: [String],
        providerLaunchAllowed: [String],
        runtimeSupportTools: [String],
        baseAskFirstTools: [String],
        surfacedAskFirstTools: [String],
        artifactBootstrapTools: [String],
        allowedToolsOverride: Bool,
        localToolCommands: [String],
        additionalPaths: [String],
        taskEnv: [String: String],
        usesDockerWorkspaceExecutor: Bool,
        mcpProjection: CopilotMCPLaunchProjection,
        dockerContainerEnvCount: Int,
        dockerCredentialProjectionCount: Int,
        browserBridgeMetadata: BrowserBridgeRuntimeLaunchMetadata
    ) -> [String: String] {
        var fields: [String: String] = [
            "runtime": id.rawValue,
            "phase": phase,
            "model": model,
            "parses_json_lines": String(plan.parsesJSONLines),
            "supports_output_format_json": String(capabilities.supportsOutputFormatJSON),
            "supports_streaming_flag": String(capabilities.supportsStreamingFlag),
            "supports_no_ask_user": String(capabilities.supportsNoAskUser),
            "supports_secret_env_vars": String(capabilities.supportsSecretEnvVars),
            "supports_allow_all": String(capabilities.supportsAllowAll),
            "supports_silent": String(capabilities.supportsSilent),
            "supports_allow_all_tools": String(capabilities.supportsAllowAllTools),
            "supports_allow_all_paths": String(capabilities.supportsAllowAllPaths),
            "supports_allow_all_urls": String(capabilities.supportsAllowAllURLs),
            "supports_available_tools": String(capabilities.supportsAvailableTools),
            "supports_excluded_tools": String(capabilities.supportsExcludedTools),
            "supports_reasoning_effort": String(capabilities.supportsReasoningEffort),
            "supports_additional_mcp_config": String(capabilities.supportsAdditionalMCPConfig),
            "requires_allow_all_tools": String(capabilities.requiresAllowAllToolsForPrompt),
            "permission_policy": effectivePermissionPolicy.rawValue,
            "allowed_tools_count": String(providerAllowed.count),
            "base_allowed_tools_count": String(baseProviderAllowed.count),
            "provider_launch_allowed_tool_count": String(providerLaunchAllowed.count),
            "runtime_support_tool_count": String(runtimeSupportTools.count),
            "runtime_support_tool_names": runtimeSupportTools.joined(separator: ","),
            "ask_first_tool_count": String(baseAskFirstTools.count),
            "ask_first_tool_names": baseAskFirstTools.joined(separator: ","),
            "surfaced_ask_first_tool_count": String(surfacedAskFirstTools.count),
            "surfaced_ask_first_tool_names": surfacedAskFirstTools.joined(separator: ","),
            "artifact_bootstrap_tool_count": String(artifactBootstrapTools.count),
            "artifact_bootstrap_tool_names": artifactBootstrapTools.joined(separator: ","),
            "artifact_bootstrap_profile": String(!artifactBootstrapTools.isEmpty),
            "allowed_tools_override": String(allowedToolsOverride),
            "local_tool_commands_count": String(localToolCommands.count),
            "additional_paths_count": String(additionalPaths.count),
            "task_env_count": String(taskEnv.count),
            "docker_workspace_executor": String(usesDockerWorkspaceExecutor),
            "docker_workspace_executor_supported": String(mcpProjection.dockerWorkspaceExecutorSupported),
            "docker_workspace_executor_unsupported_detail": mcpProjection.dockerWorkspaceUnsupportedDetail,
            "docker_workspace_tool": usesDockerWorkspaceExecutor ? DockerWorkspaceMCPProjection.providerToolPermission : "none",
            "docker_workspace_mcp_env_key_count": String(mcpProjection.workspaceExecutorEnvironment.count),
            "host_control_plane_tool_count": String(HostControlPlaneMCPProjection.toolNames.count),
            "host_control_plane_supported": String(mcpProjection.hostControlPlaneSupported),
            "host_control_plane_unsupported_detail": mcpProjection.hostControlPlaneUnsupportedDetail,
            "host_control_plane_launch_block_reason": mcpProjection.hostControlPlaneLaunchBlockReason,
            "host_control_plane_mcp_env_key_count": String(mcpProjection.hostControlEnvironment.count),
            "docker_workspace_container_env_key_count": String(dockerContainerEnvCount),
            "docker_workspace_credential_projection_count": String(dockerCredentialProjectionCount),
            "browser_bridge_mcp_tool": mcpProjection.browserBridgeMCPToolSupported ? BrowserBridgeMCPProjection.providerToolPermission : "none",
            "mcp_server_count": String(mcpProjection.configURL == nil ? 0 : mcpProjection.servers.count),
            "mcp_config_rendered": String(mcpProjection.configURL != nil),
            "uses_output_format_json": String(plan.arguments.contains("--output-format=json")),
            "uses_stream_flag": String(plan.arguments.contains("--stream=on")),
            "uses_no_ask_user": String(plan.arguments.contains("--no-ask-user")),
            "uses_reasoning_effort": String(plan.arguments.contains("--effort")),
            "uses_secret_env_vars": String(plan.arguments.contains("--secret-env-vars")),
            "uses_additional_mcp_config": String(plan.arguments.contains("--additional-mcp-config")),
            "uses_silent": String(plan.arguments.contains("--silent")),
            "uses_allow_all": String(plan.arguments.contains("--allow-all")),
            "uses_allow_all_tools": String(plan.arguments.contains("--allow-all-tools")),
            "uses_allow_all_paths": String(plan.arguments.contains("--allow-all-paths")),
            "uses_allow_all_urls": String(plan.arguments.contains("--allow-all-urls")),
            "uses_allow_tool": String(plan.arguments.contains("--allow-tool")),
            "uses_available_tools": String(plan.arguments.contains("--available-tools")),
            "uses_excluded_tools": String(plan.arguments.contains("--excluded-tools")),
            "excludes_task_tool": String(AgentRuntimeArgumentInspector.argumentList(plan.arguments, after: "--excluded-tools").contains("task"))
        ]
        fields.merge(browserBridgeMetadata.commandPlannedFields) { current, _ in current }
        return fields
    }
}
