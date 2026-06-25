import Foundation
import ASTRACore

struct CodexMCPLaunchProjection {
    let servers: [MCPRuntimeProjection.ResolvedServer]
    let configArguments: [String]
    let workspaceExecutorEnvironment: [String: String]
    let dockerWorkspaceExecutorSupported: Bool
    let dockerWorkspaceUnsupportedDetail: String
    let browserBridgeMCPToolSupported: Bool

    static func resolve(
        task: AgentTask,
        workspacePath: String,
        runID: UUID?,
        executionEnvironment: WorkspaceExecutionEnvironment,
        contextText: String
    ) -> CodexMCPLaunchProjection {
        let usesDockerWorkspaceExecutor = DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)
        var browserServerProjected = false
        var servers = MCPRuntimeProjection.enabledServers(
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
        if let browserServer = BrowserBridgeMCPProjection.resolvedServer(
            for: task,
            contextText: contextText
        ) {
            servers.append(browserServer)
            browserServerProjected = true
        }

        let configArguments = CodexMCPConfigRenderer.configArguments(servers: servers)
        let workspaceExecutorEnvironment = DockerWorkspaceMCPProjection.environmentVariables(
            task: task,
            environment: executionEnvironment,
            currentDirectory: workspacePath,
            runID: runID
        )
        let dockerWorkspaceExecutorSupported = !usesDockerWorkspaceExecutor
            || configArguments.containsMCPServerConfig(for: DockerWorkspaceMCPProjection.serverID)
        let unsupportedDetail = unsupportedDockerWorkspaceDetail(
            usesDockerWorkspaceExecutor: usesDockerWorkspaceExecutor,
            configArguments: configArguments
        )

        return CodexMCPLaunchProjection(
            servers: servers,
            configArguments: configArguments,
            workspaceExecutorEnvironment: workspaceExecutorEnvironment,
            dockerWorkspaceExecutorSupported: dockerWorkspaceExecutorSupported,
            dockerWorkspaceUnsupportedDetail: unsupportedDetail,
            browserBridgeMCPToolSupported: browserServerProjected
                && configArguments.containsMCPServerConfig(for: BrowserBridgeMCPProjection.serverID)
        )
    }

    private static func unsupportedDockerWorkspaceDetail(
        usesDockerWorkspaceExecutor: Bool,
        configArguments: [String]
    ) -> String {
        if !usesDockerWorkspaceExecutor { return "" }
        if configArguments.containsMCPServerConfig(for: DockerWorkspaceMCPProjection.serverID) {
            return ""
        }
        return "ASTRA could not render the Docker workspace shell MCP config for Codex CLI."
    }
}

enum CodexMCPConfigRenderer {
    static func configArguments(servers: [MCPRuntimeProjection.ResolvedServer]) -> [String] {
        let entries = servers.compactMap(configEntry)
        guard !entries.isEmpty else { return [] }
        return ["-c", "mcp_servers={\(entries.joined(separator: ","))}"]
    }

    private static func configEntry(
        for resolved: MCPRuntimeProjection.ResolvedServer
    ) -> String? {
        let server = resolved.server
        guard MCPEnvironmentKeyPolicy.isValidPermissionName(server.id) else {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "codex_mcp_projection",
                "result": "invalid_server_id_skipped",
                "server_id": server.id,
                "package_id": resolved.packageID
            ], level: .warning)
            return nil
        }

        var fields: [String] = []
        switch server.transport {
        case .stdio:
            guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                return nil
            }
            fields.append("command=\(tomlString(command))")
            fields.append("args=\(tomlArray(server.arguments))")
        case .http, .sse:
            guard let url = server.url?.absoluteString, !url.isEmpty else { return nil }
            fields.append("url=\(tomlString(url))")
        }

        let envVars = server.environmentKeys
            .filter { resolved.permittedEnvironmentKeys.contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isSafeEnvironmentKey)
            .sorted()
        if !envVars.isEmpty {
            fields.append("env_vars=\(tomlArray(envVars))")
        }

        return "\(tomlString(server.id))={\(fields.joined(separator: ","))}"
    }

    private static func isSafeEnvironmentKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ",") + "]"
    }

    fileprivate static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

private extension Array where Element == String {
    func containsMCPServerConfig(for serverID: String) -> Bool {
        contains { $0.contains("\(CodexMCPConfigRenderer.tomlString(serverID))={") }
    }
}
