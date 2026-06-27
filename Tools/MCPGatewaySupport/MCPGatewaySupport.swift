import Foundation

public struct RemoteMCPServerDescriptor: Equatable {
    public enum Transport: String, Equatable {
        case http
        case sse
    }

    public var id: String
    public var displayName: String
    public var transport: Transport
    public var endpoint: URL
    public var connectorBindings: [String]

    public init(
        id: String,
        displayName: String,
        transport: Transport,
        endpoint: URL,
        connectorBindings: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.endpoint = endpoint
        self.connectorBindings = connectorBindings
    }
}

public struct MCPGatewayAuthContext {
    public var authorizationHeader: String?

    public init(authorizationHeader: String? = nil) {
        self.authorizationHeader = authorizationHeader
    }
}

public protocol MCPGatewayAuthTokenProvider {
    func accessToken(for server: RemoteMCPServerDescriptor) throws -> String?
}

public protocol RemoteMCPClient: AnyObject {
    func listTools(
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> [[String: Any]]

    func callTool(
        _ name: String,
        arguments: [String: Any],
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> RemoteMCPToolResult
}

public struct RemoteMCPToolResult {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public struct EmptyMCPGatewayAuthTokenProvider: MCPGatewayAuthTokenProvider {
    public init() {}

    public func accessToken(for server: RemoteMCPServerDescriptor) throws -> String? {
        nil
    }
}

public final class LocalMCPGateway {
    private let server: RemoteMCPServerDescriptor
    private let remoteClient: RemoteMCPClient
    private let authTokenProvider: MCPGatewayAuthTokenProvider

    public init(
        server: RemoteMCPServerDescriptor,
        remoteClient: RemoteMCPClient,
        authTokenProvider: MCPGatewayAuthTokenProvider = EmptyMCPGatewayAuthTokenProvider()
    ) {
        self.server = server
        self.remoteClient = remoteClient
        self.authTokenProvider = authTokenProvider
    }

    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = object["method"] as? String else {
            return encodeError(id: nil, code: -32700, message: "Invalid JSON-RPC request")
        }

        let id = object["id"]
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        switch method {
        case "initialize":
            return encodeResult(id: id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "astra-mcp-gateway", "version": "1.0.0"]
            ])
        case "tools/list":
            return handleToolsList(id: id)
        case "tools/call":
            return handleToolCall(id: id, object: object)
        default:
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    private func handleToolsList(id: Any?) -> String? {
        do {
            let tools = try remoteClient.listTools(for: server, auth: authContext())
            return encodeResult(id: id, result: ["tools": tools])
        } catch {
            return encodeError(id: id, code: -32000, message: "Remote MCP tool discovery failed: \(error.localizedDescription)")
        }
    }

    private func handleToolCall(id: Any?, object: [String: Any]) -> String? {
        guard let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String,
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try remoteClient.callTool(
                toolName,
                arguments: arguments,
                for: server,
                auth: authContext()
            )
            return encodeResult(id: id, result: [
                "content": [[
                    "type": "text",
                    "text": result.text
                ]],
                "isError": result.isError
            ])
        } catch {
            return encodeResult(id: id, result: [
                "content": [[
                    "type": "text",
                    "text": "Remote MCP tool call failed: \(error.localizedDescription)"
                ]],
                "isError": true
            ])
        }
    }

    private func authContext() throws -> MCPGatewayAuthContext {
        guard let token = try authTokenProvider.accessToken(for: server),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPGatewayAuthContext()
        }
        return MCPGatewayAuthContext(authorizationHeader: "Bearer \(token)")
    }

    private func encodeResult(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": normalizedID(id), "result": result])
    }

    private func encodeError(id: Any?, code: Int, message: String) -> String? {
        encode([
            "jsonrpc": "2.0",
            "id": normalizedID(id),
            "error": ["code": code, "message": message]
        ])
    }

    private func normalizedID(_ id: Any?) -> Any {
        switch id {
        case let value as String: return value
        case let value as NSNumber: return value
        case .none: return NSNull()
        default: return NSNull()
        }
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

public final class UnconfiguredRemoteMCPClient: RemoteMCPClient {
    public init() {}

    public func listTools(
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> [[String: Any]] {
        []
    }

    public func callTool(
        _ name: String,
        arguments: [String: Any],
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> RemoteMCPToolResult {
        RemoteMCPToolResult(
            text: "Remote MCP backend \(server.id) is not configured in this ASTRA gateway skeleton.",
            isError: true
        )
    }
}

public enum AstraMCPGatewayToolMain {
    public static func run(arguments: [String] = CommandLine.arguments) {
        let options = GatewayCommandOptions(arguments: Array(arguments.dropFirst()))
        let descriptor = RemoteMCPServerDescriptor(
            id: options.serverID,
            displayName: options.serverID,
            transport: .http,
            endpoint: URL(string: "http://127.0.0.1/astra-mcp-gateway-placeholder")!,
            connectorBindings: []
        )
        let gateway = LocalMCPGateway(
            server: descriptor,
            remoteClient: UnconfiguredRemoteMCPClient(),
            authTokenProvider: EmptyMCPGatewayAuthTokenProvider()
        )
        while let line = readLine() {
            if let response = gateway.handleLine(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}

private struct GatewayCommandOptions {
    var packageID: String = ""
    var serverID: String = "remote"

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            switch value {
            case "--package-id" where index + 1 < arguments.count:
                packageID = arguments[index + 1]
                index += 2
            case "--server-id" where index + 1 < arguments.count:
                serverID = arguments[index + 1]
                index += 2
            default:
                index += 1
            }
        }
    }
}
