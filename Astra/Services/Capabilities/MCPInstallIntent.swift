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

struct MCPInstallSetupCommand: Equatable {
    enum Purpose: Equatable {
        case generateConfig
        case importConfig
        case guidedSetup
    }

    var purpose: Purpose
    var command: String
    var arguments: [String]
    var installSource: PluginMCPInstallSource?
    var guidance: String
}

struct MCPInstallIntent: Equatable {
    enum Kind: Equatable {
        case stdioCommand
        case remoteURL
        case configJSON
        case setupCommand
    }

    var rawInput: String
    var kind: Kind
    var serverID: String?
    var displayName: String?
    var transport: PluginMCPServer.Transport
    var command: String?
    var arguments: [String]
    var url: URL?
    var installSource: PluginMCPInstallSource?
    var serverSpecs: [MCPInstallServerSpec]
    var setupCommand: MCPInstallSetupCommand?

    init(
        rawInput: String,
        kind: Kind,
        serverID: String?,
        displayName: String?,
        transport: PluginMCPServer.Transport,
        command: String?,
        arguments: [String],
        url: URL?,
        installSource: PluginMCPInstallSource?,
        serverSpecs: [MCPInstallServerSpec]? = nil,
        setupCommand: MCPInstallSetupCommand? = nil
    ) {
        self.rawInput = rawInput
        self.kind = kind
        self.serverID = serverID
        self.displayName = displayName
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.installSource = installSource
        self.setupCommand = setupCommand
        self.serverSpecs = serverSpecs ?? Self.inferredServerSpecs(
            kind: kind,
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
        kind: Kind,
        serverID: String?,
        displayName: String?,
        transport: PluginMCPServer.Transport,
        command: String?,
        arguments: [String],
        url: URL?,
        installSource: PluginMCPInstallSource?
    ) -> [MCPInstallServerSpec] {
        guard kind != .setupCommand else { return [] }
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
