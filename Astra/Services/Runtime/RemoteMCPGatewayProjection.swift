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
            gatewayAccessTokenBinding(binding) == nil ? nil : binding.destination
        })
    }

    static func shouldRouteThroughGateway(_ server: PluginMCPServer) -> Bool {
        server.transport != .stdio
            && !server.connectorBindings.isEmpty
            && gatewayAccessTokenBinding(server.controlPlane?.runtimeBindings ?? []) != nil
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
        guard let binding = gatewayAccessTokenBinding(server.controlPlane?.runtimeBindings ?? []) else {
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
                "--endpoint", server.url?.absoluteString ?? "",
                "--access-token-env", accessTokenEnvironmentKey
            ],
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

    private static func gatewayAccessTokenBinding(
        _ bindings: [MCPRuntimeBindingTemplate]
    ) -> MCPRuntimeBindingTemplate? {
        bindings.first { gatewayAccessTokenBinding($0) != nil }
    }

    private static func gatewayAccessTokenBinding(
        _ binding: MCPRuntimeBindingTemplate
    ) -> MCPRuntimeBindingTemplate? {
        guard binding.destination == .httpHeader,
              binding.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Authorization") == .orderedSame,
              binding.template.count == 2 else {
            return nil
        }
        guard binding.template[0].kind == .literal,
              binding.template[0].literal == "Bearer ",
              binding.template[0].reference == nil else {
            return nil
        }
        guard binding.template[1].kind == .reference,
              binding.template[1].literal == nil,
              binding.template[1].reference?.kind == .secretRef,
              binding.template[1].reference?.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return binding
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
