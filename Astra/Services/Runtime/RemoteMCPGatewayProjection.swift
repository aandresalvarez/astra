import Foundation
import ASTRACore

enum RemoteMCPGatewayProjection {
    static let executableName = "astra-mcp-gateway"

    static var executablePath: String {
        (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent(executableName)
    }

    static func shouldRouteThroughGateway(_ server: PluginMCPServer) -> Bool {
        server.transport != .stdio && !server.connectorBindings.isEmpty
    }

    static func providerFacingServer(for resolved: MCPRuntimeProjection.ResolvedServer) -> PluginMCPServer {
        let server = resolved.server
        guard shouldRouteThroughGateway(server) else { return server }
        var arguments = [
            "--package-id", resolved.packageID,
            "--server-id", server.id
        ]
        if let endpoint = server.url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpoint.isEmpty {
            arguments.append(contentsOf: ["--endpoint", endpoint])
        }
        return PluginMCPServer(
            id: server.id,
            displayName: server.displayName,
            transport: .stdio,
            command: executablePath,
            arguments: arguments,
            environmentKeys: [],
            connectorBindings: server.connectorBindings,
            allowedTools: server.allowedTools,
            excludedTools: server.excludedTools,
            resourcesEnabled: server.resourcesEnabled,
            promptsEnabled: server.promptsEnabled,
            trustLevel: server.trustLevel,
            installSource: server.installSource
        )
    }
}
