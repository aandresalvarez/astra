import Foundation
import ASTRACore

struct MCPInstallServerSpec: Equatable {
    var serverID: String
    var displayName: String?
    var transport: PluginMCPServer.Transport
    var command: String?
    var arguments: [String]
    var url: URL?
    var environmentKeys: [String]
    var installSource: PluginMCPInstallSource?
}

struct MCPInstallIntent: Equatable {
    var serverID: String?
    var displayName: String?
    var transport: PluginMCPServer.Transport
    var command: String?
    var arguments: [String]
    var url: URL?
    var installSource: PluginMCPInstallSource?
    var serverSpecs: [MCPInstallServerSpec]

    init(
        serverID: String?,
        displayName: String?,
        transport: PluginMCPServer.Transport,
        command: String?,
        arguments: [String],
        url: URL?,
        installSource: PluginMCPInstallSource?,
        serverSpecs: [MCPInstallServerSpec]? = nil
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.installSource = installSource
        self.serverSpecs = serverSpecs ?? Self.inferredServerSpecs(
            serverID: serverID,
            displayName: displayName,
            transport: transport,
            command: command,
            arguments: arguments,
            url: url,
            installSource: installSource
        )
    }

    private static func inferredServerSpecs(
        serverID: String?,
        displayName: String?,
        transport: PluginMCPServer.Transport,
        command: String?,
        arguments: [String],
        url: URL?,
        installSource: PluginMCPInstallSource?
    ) -> [MCPInstallServerSpec] {
        let normalizedID = serverID ?? installSource?.identifier ?? "mcp"
        switch transport {
        case .stdio:
            guard command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return []
            }
        case .http, .sse:
            guard url != nil else { return [] }
        }
        return [
            MCPInstallServerSpec(
                serverID: normalizedID,
                displayName: displayName,
                transport: transport,
                command: command,
                arguments: arguments,
                url: url,
                environmentKeys: [],
                installSource: installSource
            )
        ]
    }
}
