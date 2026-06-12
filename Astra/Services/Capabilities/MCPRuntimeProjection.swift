import Foundation
import ASTRACore

/// Materializes capability-package MCP server declarations into runtime
/// configuration. This is the delivery half of the MCP story: packages
/// declare servers (`PluginMCPServer`), the catalog validates and governs
/// them, and this projection turns the enabled+approved set into the config
/// a runtime launch actually consumes.
///
/// Secrets never enter the rendered config file. Environment bindings are
/// written as `${KEY}` references that the runtime expands from its own
/// process environment — which already carries connector credentials via
/// `ConnectorRuntimeProjection`.
enum MCPRuntimeProjection {

    struct ResolvedServer: Equatable {
        var packageID: String
        var server: PluginMCPServer
    }

    /// Enabled, policy-runnable MCP servers for a workspace, in the same
    /// deterministic order as `TaskCapabilityResolver.enabledMCPServerManifests`.
    /// Duplicate server IDs across packages keep the first occurrence.
    static func enabledServers(
        for workspace: Workspace?,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord]
    ) -> [ResolvedServer] {
        guard let workspace else { return [] }
        let enabledPackageIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledPackageIDs.isEmpty else { return [] }
        let context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            approvalRecords: approvalRecords
        )

        let servers = packages
            .filter { enabledPackageIDs.contains($0.id) }
            .filter { CapabilityCatalogPolicy.decision(for: $0, context: context).canRun }
            .flatMap { package in
                package.mcpServers.map { ResolvedServer(packageID: package.id, server: $0) }
            }
            .sorted {
                if $0.packageID != $1.packageID { return $0.packageID < $1.packageID }
                return $0.server.id < $1.server.id
            }

        var seenIDs = Set<String>()
        return servers.filter { resolved in
            guard seenIDs.insert(resolved.server.id).inserted else {
                AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                    "source": "mcp_projection",
                    "result": "duplicate_server_id_skipped",
                    "server_id": resolved.server.id,
                    "package_id": resolved.packageID
                ], level: .warning)
                return false
            }
            return true
        }
    }

    // MARK: - Claude Code config

    /// Renders the `--mcp-config` JSON for Claude Code:
    /// `{"mcpServers": {"<id>": {"type": ..., "command"/"url": ..., "env": {...}}}}`.
    /// Returns nil when there is nothing to deliver.
    static func claudeConfigJSON(servers: [ResolvedServer]) -> Data? {
        guard !servers.isEmpty else { return nil }
        var entries: [String: [String: Any]] = [:]
        for resolved in servers {
            let server = resolved.server
            var entry: [String: Any] = ["type": server.transport.rawValue]
            switch server.transport {
            case .stdio:
                guard let command = server.command, !command.isEmpty else { continue }
                entry["command"] = command
                if !server.arguments.isEmpty {
                    entry["args"] = server.arguments
                }
            case .http, .sse:
                guard let url = server.url else { continue }
                entry["url"] = url.absoluteString
            }
            if !server.environmentKeys.isEmpty {
                // ${KEY} indirection: the value comes from the runtime's
                // process environment at expansion time, so the config file
                // on disk never contains credential material.
                entry["env"] = Dictionary(
                    uniqueKeysWithValues: server.environmentKeys.map { ($0, "${\($0)}") }
                )
            }
            entries[server.id] = entry
        }
        guard !entries.isEmpty else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: ["mcpServers": entries],
            options: [.sortedKeys, .prettyPrinted]
        )
    }

    /// Writes the rendered Claude config to a per-launch file and returns
    /// its path. The file contains no secrets (env indirection), so the
    /// temporary directory is an acceptable home; one file per launch keeps
    /// concurrent runs independent.
    static func writeClaudeConfig(
        servers: [ResolvedServer],
        taskID: UUID
    ) -> URL? {
        guard let data = claudeConfigJSON(servers: servers) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-mcp-configs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent("\(taskID.uuidString)-\(UUID().uuidString)")
                .appendingPathExtension("json")
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "mcp_projection",
                "result": "config_write_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    // MARK: - Tool permissions

    /// Permission entries for the runtime allow list. A server with an
    /// explicit `allowedTools` list grants only those tools
    /// (`mcp__<server>__<tool>`); an empty list grants the whole server
    /// (`mcp__<server>`).
    static func allowedToolPermissions(servers: [ResolvedServer]) -> [String] {
        servers.flatMap { resolved -> [String] in
            let server = resolved.server
            if server.allowedTools.isEmpty {
                return ["mcp__\(server.id)"]
            }
            return server.allowedTools.map { "mcp__\(server.id)__\($0)" }
        }
    }

    /// Permission entries for the runtime deny list from `excludedTools`.
    static func deniedToolPermissions(servers: [ResolvedServer]) -> [String] {
        servers.flatMap { resolved in
            resolved.server.excludedTools.map { "mcp__\(resolved.server.id)__\($0)" }
        }
    }

    // MARK: - Preflight

    enum PreflightIssue: Equatable {
        case missingExecutable(serverID: String, command: String)

        var message: String {
            switch self {
            case .missingExecutable(let serverID, let command):
                return "MCP server \(serverID) needs \(command), which was not found. Install it or disable the capability that provides this server."
            }
        }
    }

    /// Launch-blocking issues for the resolved server set: a stdio server
    /// whose command cannot be resolved to an executable would make the
    /// runtime fail opaquely mid-run, so it fails fast here instead.
    static func preflightIssues(
        servers: [ResolvedServer],
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> [PreflightIssue] {
        servers.compactMap { resolved in
            let server = resolved.server
            guard server.transport == .stdio, let command = server.command, !command.isEmpty else {
                return nil
            }
            if command.hasPrefix("/") {
                return FileManager.default.isExecutableFile(atPath: command)
                    ? nil
                    : .missingExecutable(serverID: server.id, command: command)
            }
            return detectExecutable(command).isEmpty
                ? .missingExecutable(serverID: server.id, command: command)
                : nil
        }
    }
}
