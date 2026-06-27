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
/// Which environment variables an MCP server may request. `environmentKeys`
/// is package-controlled and the runtime expands `${KEY}` from the full host
/// environment — without gating, a package could declare
/// `AWS_SECRET_ACCESS_KEY` and exfiltrate host credentials to its own
/// server. A server may only request keys its own package declares
/// (connector credential/config hints and skill environment keys): those are
/// the secrets the user consented to when configuring that package.
enum MCPEnvironmentKeyPolicy {
    static func declaredKeys(in package: PluginPackage) -> Set<String> {
        var keys = Set(package.connectors.flatMap { connector in
            connector.credentialHints.map(\.key) + connector.configHints.map(\.key)
        })
        keys.formUnion(package.skills.flatMap(\.environmentKeys))
        return keys
    }

    /// Permission strings are composed as `mcp__<server>__<tool>`; names
    /// containing `__`, whitespace, or other separators could collide or be
    /// parsed differently by the CLI than ASTRA intends.
    private static let permissionNameRule =
        "must start with a letter or digit, use only letters, digits, dots, hyphens, or underscores, and contain no double underscore (the mcp__ permission delimiter)"

    static func invalidNameReason(server: PluginMCPServer) -> String? {
        if !isValidPermissionName(server.id) {
            return "server id \"\(server.id)\" \(permissionNameRule)"
        }
        for tool in server.allowedTools + server.excludedTools where !isValidPermissionName(tool) {
            return "tool name \"\(tool)\" \(permissionNameRule)"
        }
        return nil
    }

    static func isValidPermissionName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("__") else { return false }
        return name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    static func undeclaredKeys(server: PluginMCPServer, package: PluginPackage) -> [String] {
        let declared = declaredKeys(in: package)
        return server.environmentKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !declared.contains($0) }
            .sorted()
    }
}

enum MCPRuntimeProjection {

    struct ResolvedServer: Equatable {
        var packageID: String
        var server: PluginMCPServer
        /// Env keys this server may receive, computed against its package's
        /// declared keys. Defaults to all of the server's keys for direct
        /// construction in tests; `enabledServers` always applies the policy.
        var permittedEnvironmentKeys: Set<String>

        init(
            packageID: String,
            server: PluginMCPServer,
            permittedEnvironmentKeys: Set<String>? = nil
        ) {
            self.packageID = packageID
            self.server = server
            self.permittedEnvironmentKeys = permittedEnvironmentKeys ?? Set(server.environmentKeys)
        }
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
        return enabledServers(
            enabledPackageIDs: Set(workspace.enabledCapabilityIDs),
            installedPackageIDs: workspace.installedPluginIDSet,
            packages: packages,
            approvalRecords: approvalRecords
        )
    }

    static func enabledServers(
        enabledPackageIDs: Set<String>,
        installedPackageIDs: Set<String>,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord]
    ) -> [ResolvedServer] {
        guard !enabledPackageIDs.isEmpty else { return [] }
        // The run executes on behalf of the local user, who is the admin of
        // their own catalog (single-user model). A non-admin context would
        // drop an admin-only package's servers at launch even though the
        // package is enabled — use the canonical currentUser factory.
        let context = CapabilityCatalogPolicyContext.currentUser(
            enabledPackageIDs: enabledPackageIDs,
            installedPackageIDs: installedPackageIDs,
            approvalRecords: approvalRecords
        )

        let servers = packages
            .filter { enabledPackageIDs.contains($0.id) }
            .filter { CapabilityCatalogPolicy.decision(for: $0, context: context).canRun }
            .flatMap { package in
                package.mcpServers.map { server in
                    let undeclared = MCPEnvironmentKeyPolicy.undeclaredKeys(server: server, package: package)
                    if !undeclared.isEmpty {
                        AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                            "source": "mcp_projection",
                            "result": "undeclared_env_keys_dropped",
                            "server_id": server.id,
                            "package_id": package.id,
                            "dropped_key_names": undeclared.joined(separator: ",")
                        ], level: .warning)
                    }
                    return ResolvedServer(
                        packageID: package.id,
                        server: server,
                        permittedEnvironmentKeys: Set(server.environmentKeys).subtracting(undeclared)
                    )
                }
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
    static func claudeConfigJSON(
        servers: [ResolvedServer],
        availableEnvironment: [String: String] = [:]
    ) -> Data? {
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
            let envKeys = server.environmentKeys
                .filter { resolved.permittedEnvironmentKeys.contains($0) }
                .filter { availableEnvironment[$0]?.isEmpty == false }
            if !envKeys.isEmpty {
                // ${KEY} indirection: the value comes from the runtime's
                // explicit ASTRA-projected launch environment, so the config
                // file on disk never contains credential material and a server
                // cannot request arbitrary inherited host secrets.
                entry["env"] = Dictionary(
                    uniqueKeysWithValues: envKeys.map { ($0, "${\($0)}") }
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
        taskID: UUID,
        availableEnvironment: [String: String] = [:],
        allowEmpty: Bool = false
    ) -> URL? {
        let emptyConfig = Data(#"{"mcpServers":{}}"#.utf8)
        guard let data = claudeConfigJSON(servers: servers, availableEnvironment: availableEnvironment) ?? (allowEmpty ? emptyConfig : nil) else { return nil }

        // Preferred: a private 0700 subdir that can be pruned. Fallback: the
        // temp-dir root, so a stale file blocking the subdir (or a subdir
        // creation hiccup) still yields a config URL. Returning nil here would
        // strip --mcp-config AND --strict-mcp-config from the launch and
        // re-open the repo .mcp.json bypass, so we try hard not to.
        let privateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-mcp-configs", isDirectory: true)
        if let url = writeConfigFile(data, taskID: taskID, into: privateDir, prune: true) {
            return url
        }
        if let url = writeConfigFile(data, taskID: taskID, into: FileManager.default.temporaryDirectory, prune: false) {
            return url
        }
        AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
            "source": "mcp_projection",
            "result": "config_write_failed_all_locations"
        ], level: .error)
        return nil
    }

    private static func writeConfigFile(
        _ data: Data,
        taskID: UUID,
        into directory: URL,
        prune: Bool
    ) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if prune { pruneStaleConfigs(in: directory) }
            let url = directory
                .appendingPathComponent("astra-mcp-\(taskID.uuidString)-\(UUID().uuidString)")
                .appendingPathExtension("json")
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "mcp_projection",
                "result": "config_write_failed",
                "directory": directory.lastPathComponent,
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    /// Configs are per-launch and nothing tracks process exit here, so each
    /// write sweeps siblings older than a day. Bounds disk growth and limits
    /// how long the workspace's MCP topology lingers on disk.
    private static func pruneStaleConfigs(
        in directory: URL,
        olderThan interval: TimeInterval = 24 * 60 * 60
    ) {
        let cutoff = Date().addingTimeInterval(-interval)
        let urls = (try? HostFileAccessBroker().contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            intent: .astraManagedStorage(root: directory)
        )) ?? []
        for url in urls where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
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
        case missingExecutableWithInstallSource(serverID: String, command: String, source: PluginMCPInstallSource)

        var message: String {
            switch self {
            case .missingExecutable(let serverID, let command):
                return "MCP server \(serverID) needs \(command), which was not found. Install it or disable the capability that provides this server."
            case .missingExecutableWithInstallSource(let serverID, let command, let source):
                return "MCP server \(serverID) needs \(command), which was not found. Install \(MCPInstallSourceFormatter.installDescription(for: source)) or disable the capability that provides this server."
            }
        }
    }

    /// Launch-blocking issues for the resolved server set: a stdio server
    /// whose command cannot be resolved to an executable would make the
    /// runtime fail opaquely mid-run, so it fails fast here instead.
    static func preflightIssues(
        servers: [ResolvedServer],
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [PreflightIssue] {
        servers.compactMap { resolved in
            let server = resolved.server
            guard server.transport == .stdio, let command = server.command, !command.isEmpty else {
                return nil
            }
            if command.hasPrefix("/") {
                return isExecutableFile(command)
                    ? nil
                    : missingExecutableIssue(for: server, command: command)
            }
            return detectExecutable(command).isEmpty
                ? missingExecutableIssue(for: server, command: command)
                : nil
        }
    }

    private static func missingExecutableIssue(
        for server: PluginMCPServer,
        command: String
    ) -> PreflightIssue {
        if let source = server.installSource {
            return .missingExecutableWithInstallSource(serverID: server.id, command: command, source: source)
        }
        return .missingExecutable(serverID: server.id, command: command)
    }

}
