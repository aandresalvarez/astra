import Foundation
import ASTRACore

enum RemoteMCPGatewayProjection {
    static let executableName = "astra-mcp-gateway"

    static var executablePath: String {
        (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent(executableName)
    }

    static func gatewayAccessTokenEnvironmentKey(
        packageID: String,
        serverID: String,
        bindingID: String
    ) -> String {
        [
            "ASTRA_MCP_GATEWAY",
            environmentKeyComponent(packageID),
            environmentKeyComponent(serverID),
            environmentKeyComponent(bindingID)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "_")
    }

    static func projectableGatewayBindingDestinations(
        controlPlane: MCPControlPlaneMetadata?
    ) -> [MCPRuntimeBindingDestination] {
        orderedUnique((controlPlane?.runtimeBindings ?? []).compactMap { binding in
            RemoteMCPGatewayEndpointTrustPolicy.gatewayAccessTokenBinding(binding) == nil ? nil : binding.destination
        })
    }

    static func shouldRouteThroughGateway(_ server: PluginMCPServer) -> Bool {
        RemoteMCPGatewayEndpointTrustPolicy.isCredentialForwardingGatewayCandidate(server)
    }

    static func providerFacingResolvedServer(
        for resolved: MCPRuntimeProjection.ResolvedServer
    ) -> MCPRuntimeProjection.ResolvedServer? {
        let server = resolved.server
        guard shouldRouteThroughGateway(server) else {
            if server.transport != .stdio && !server.connectorBindings.isEmpty {
                return nil
            }
            return resolved
        }
        guard RemoteMCPGatewayEndpointTrustPolicy.credentialForwardingEndpointViolation(
            packageID: resolved.packageID,
            packageSourceMetadata: resolved.packageSourceMetadata,
            server: server
        ) == nil else {
            return nil
        }
        guard let binding = RemoteMCPGatewayEndpointTrustPolicy.gatewayAccessTokenBinding(
            in: server.controlPlane
        ) else {
            return nil
        }
        guard let endpoint = server.url?.absoluteString,
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let accessTokenEnvironmentKey = gatewayAccessTokenEnvironmentKey(
            packageID: resolved.packageID,
            serverID: server.id,
            bindingID: binding.id
        )
        let gatewayServer = PluginMCPServer(
            id: server.id,
            displayName: server.displayName,
            transport: .stdio,
            command: executablePath,
            arguments: [
                "--package-id", resolved.packageID,
                "--server-id", server.id,
                "--endpoint", endpoint,
                "--access-token-env", accessTokenEnvironmentKey
            ] + gatewayPolicyArguments(for: server),
            environmentKeys: [accessTokenEnvironmentKey],
            connectorBindings: server.connectorBindings,
            allowedTools: server.allowedTools,
            excludedTools: server.excludedTools,
            resourcesEnabled: server.resourcesEnabled,
            promptsEnabled: server.promptsEnabled,
            trustLevel: server.trustLevel,
            installSource: server.installSource,
            remoteRegistry: server.remoteRegistry,
            controlPlane: server.controlPlane
        )
        return MCPRuntimeProjection.ResolvedServer(
            packageID: resolved.packageID,
            packageSourceMetadata: resolved.packageSourceMetadata,
            server: gatewayServer,
            permittedEnvironmentKeys: [accessTokenEnvironmentKey]
        )
    }

    static func missingRequiredEnvironmentKeys(
        for server: PluginMCPServer,
        availableEnvironment: [String: String]
    ) -> [String] {
        gatewayAccessTokenEnvironmentKeys(in: server.arguments).filter { key in
            availableEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
    }

    private static func gatewayPolicyArguments(for server: PluginMCPServer) -> [String] {
        let policy = gatewayToolPolicy(for: server)
        guard !policy.accessByToolName.isEmpty else {
            return policy.requiresExplicitPolicy ? ["--gateway-tool-policy-required"] : []
        }

        let allowedToolNames = Set(server.allowedTools.map(normalized).filter { !$0.isEmpty })
        let excludedToolNames = Set(server.excludedTools.map(normalized).filter { !$0.isEmpty })
        let selectedRules = policy.accessByToolName.filter { toolName, _ in
            let normalizedToolName = normalized(toolName)
            guard !excludedToolNames.contains(normalizedToolName) else { return false }
            return allowedToolNames.isEmpty || allowedToolNames.contains(normalizedToolName)
        }
        guard !selectedRules.isEmpty else { return ["--gateway-tool-policy-required"] }

        var arguments = ["--gateway-tool-policy-required"]
        for option in [
            "--gateway-read-tool",
            "--gateway-write-tool",
            "--gateway-send-tool",
            "--gateway-delete-tool",
            "--gateway-admin-tool"
        ] {
            let toolNames = selectedRules
                .filter { _, toolOption in toolOption == option }
                .map(\.key)
                .sorted()
            for toolName in toolNames {
                arguments += [option, toolName]
            }
        }
        return arguments
    }

    private struct GatewayToolPolicy {
        var accessByToolName: [String: String]
        var requiresExplicitPolicy: Bool
    }

    private static func gatewayToolPolicy(for server: PluginMCPServer) -> GatewayToolPolicy {
        if let product = GoogleWorkspaceRemoteMCPRegistry.products.first(where: { $0.serverID == server.id }) {
            return GatewayToolPolicy(
                accessByToolName: mostRestrictiveGatewayOptions(
                    product.toolFamilies.map { toolName, family in (toolName, gatewayPolicyOption(for: family)) }
                ),
                requiresExplicitPolicy: true
            )
        }

        let registryClassifications = server.remoteRegistry?.toolClassifications ?? []
        guard !registryClassifications.isEmpty else {
            return GatewayToolPolicy(accessByToolName: [:], requiresExplicitPolicy: false)
        }
        return GatewayToolPolicy(
            accessByToolName: mostRestrictiveGatewayOptions(
                registryClassifications.map { ($0.toolName, gatewayPolicyOption(for: $0.effect)) }
            ),
            requiresExplicitPolicy: true
        )
    }

    private static func mostRestrictiveGatewayOptions(_ entries: [(String, String)]) -> [String: String] {
        let selected = entries.reduce(into: [String: (toolName: String, option: String)]()) { result, entry in
            let toolName = entry.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(toolName)
            guard !key.isEmpty else { return }
            guard let existing = result[key] else {
                result[key] = (toolName, entry.1)
                return
            }
            if gatewayPolicyOptionRank(entry.1) > gatewayPolicyOptionRank(existing.option) {
                result[key] = (toolName, entry.1)
            }
        }
        return Dictionary(uniqueKeysWithValues: selected.values.map { ($0.toolName, $0.option) })
    }

    private static func gatewayPolicyOptionRank(_ option: String) -> Int {
        switch option {
        case "--gateway-read-tool":
            return 0
        case "--gateway-write-tool":
            return 1
        case "--gateway-send-tool":
            return 2
        case "--gateway-delete-tool":
            return 3
        case "--gateway-admin-tool":
            return 4
        default:
            return 5
        }
    }

    private static func gatewayPolicyOption(for effect: RemoteMCPToolEffect) -> String {
        switch effect {
        case .read:
            return "--gateway-read-tool"
        case .write:
            return "--gateway-write-tool"
        case .send:
            return "--gateway-send-tool"
        case .delete:
            return "--gateway-delete-tool"
        case .admin:
            return "--gateway-admin-tool"
        }
    }

    private static func gatewayPolicyOption(for family: GoogleWorkspaceRemoteMCPToolFamily) -> String {
        switch family {
        case .read, .permissionRead, .download, .availabilityRead:
            return "--gateway-read-tool"
        case .draft, .label, .write:
            return "--gateway-write-tool"
        case .response:
            return "--gateway-send-tool"
        case .delete:
            return "--gateway-delete-tool"
        }
    }
    private static func environmentKeyComponent(_ value: String) -> String {
        let mapped = value.uppercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        return String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func gatewayAccessTokenEnvironmentKeys(in arguments: [String]) -> [String] {
        var keys: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--access-token-env", index + 1 < arguments.count {
                keys.append(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return keys
    }

    private static func orderedUnique<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
