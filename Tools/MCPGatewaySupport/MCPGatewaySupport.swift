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

public enum MCPGatewayToolAccess: String, Equatable {
    case read
    case write
    case send
    case delete
    case admin

    var requiresNativeApproval: Bool {
        switch self {
        case .read:
            return false
        case .write, .send, .delete, .admin:
            return true
        }
    }
}

public struct MCPGatewayToolPolicyRule: Equatable {
    public var toolName: String
    public var access: MCPGatewayToolAccess
    public var nativeApprovalGranted: Bool

    public init(
        toolName: String,
        access: MCPGatewayToolAccess,
        nativeApprovalGranted: Bool = false
    ) {
        self.toolName = toolName
        self.access = access
        self.nativeApprovalGranted = nativeApprovalGranted
    }
}

public enum MCPGatewayToolPolicyDecision: Equatable {
    case allowed
    case denied(String)
}

public protocol MCPGatewayToolPolicyEnforcing {
    func decision(
        forTool toolName: String,
        server: RemoteMCPServerDescriptor
    ) -> MCPGatewayToolPolicyDecision
}

public struct AllowingMCPGatewayToolPolicyEnforcer: MCPGatewayToolPolicyEnforcing {
    public init() {}

    public func decision(
        forTool _: String,
        server _: RemoteMCPServerDescriptor
    ) -> MCPGatewayToolPolicyDecision {
        .allowed
    }
}

public struct ConfiguredMCPGatewayToolPolicyEnforcer: MCPGatewayToolPolicyEnforcing {
    private let rulesByToolName: [String: MCPGatewayToolPolicyRule]
    private let requiresExplicitPolicy: Bool

    public init(
        rules: [MCPGatewayToolPolicyRule],
        requiresExplicitPolicy: Bool = true
    ) {
        self.rulesByToolName = Self.mostRestrictiveRulesByToolName(rules)
        self.requiresExplicitPolicy = requiresExplicitPolicy
    }

    public func decision(
        forTool toolName: String,
        server _: RemoteMCPServerDescriptor
    ) -> MCPGatewayToolPolicyDecision {
        guard let rule = rulesByToolName[Self.normalized(toolName)] else {
            if requiresExplicitPolicy {
                return .denied("Gateway policy has no classification for tool \(trimmed(toolName)).")
            }
            return .allowed
        }
        guard !rule.access.requiresNativeApproval || rule.nativeApprovalGranted else {
            return .denied("Native approval required for \(rule.access.rawValue) tool \(trimmed(toolName)).")
        }
        return .allowed
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func mostRestrictiveRulesByToolName(
        _ rules: [MCPGatewayToolPolicyRule]
    ) -> [String: MCPGatewayToolPolicyRule] {
        rules.reduce(into: [:]) { result, rule in
            let key = normalized(rule.toolName)
            guard !key.isEmpty else { return }
            guard let existing = result[key] else {
                result[key] = rule
                return
            }
            if rule.access.restrictionRank > existing.access.restrictionRank {
                result[key] = rule
            } else if rule.access == existing.access {
                var merged = existing
                merged.nativeApprovalGranted = existing.nativeApprovalGranted && rule.nativeApprovalGranted
                result[key] = merged
            }
        }
    }
}

public struct EmptyMCPGatewayAuthTokenProvider: MCPGatewayAuthTokenProvider {
    public init() {}

    public func accessToken(for server: RemoteMCPServerDescriptor) throws -> String? {
        nil
    }
}

public struct EnvironmentMCPGatewayAuthTokenProvider: MCPGatewayAuthTokenProvider {
    private let variableName: String
    private let environment: [String: String]

    public init(
        variableName: String = "ASTRA_MCP_GATEWAY_ACCESS_TOKEN",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.variableName = variableName
        self.environment = environment
    }

    public func accessToken(for server: RemoteMCPServerDescriptor) throws -> String? {
        environment[variableName]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class LocalMCPGateway {
    private let server: RemoteMCPServerDescriptor
    private let remoteClient: RemoteMCPClient
    private let authTokenProvider: MCPGatewayAuthTokenProvider
    private let toolPolicyEnforcer: any MCPGatewayToolPolicyEnforcing

    public init(
        server: RemoteMCPServerDescriptor,
        remoteClient: RemoteMCPClient,
        authTokenProvider: MCPGatewayAuthTokenProvider = EmptyMCPGatewayAuthTokenProvider(),
        toolPolicyEnforcer: any MCPGatewayToolPolicyEnforcing = AllowingMCPGatewayToolPolicyEnforcer()
    ) {
        self.server = server
        self.remoteClient = remoteClient
        self.authTokenProvider = authTokenProvider
        self.toolPolicyEnforcer = toolPolicyEnforcer
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
        switch toolPolicyEnforcer.decision(forTool: toolName, server: server) {
        case .allowed:
            break
        case .denied(let reason):
            return encodeResult(id: id, result: [
                "content": [[
                    "type": "text",
                    "text": "Remote MCP tool call blocked by ASTRA policy: \(reason)"
                ]],
                "isError": true
            ])
        }
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
            endpoint: options.endpoint ?? URL(string: "http://127.0.0.1/astra-mcp-gateway-unconfigured")!,
            connectorBindings: []
        )
        let gateway = LocalMCPGateway(
            server: descriptor,
            remoteClient: options.endpoint == nil ? UnconfiguredRemoteMCPClient() : RemoteMCPHTTPClient(),
            authTokenProvider: EnvironmentMCPGatewayAuthTokenProvider(variableName: options.accessTokenEnvironmentKey),
            toolPolicyEnforcer: options.toolPolicyEnforcer
        )
        while let line = readLine() {
            if let response = gateway.handleLine(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}

struct GatewayCommandOptions {
    var packageID: String = ""
    var serverID: String = "remote"
    var endpoint: URL?
    var accessTokenEnvironmentKey: String = "ASTRA_MCP_GATEWAY_ACCESS_TOKEN"
    var toolPolicyRequired = false
    var toolAccessByName: [String: MCPGatewayToolAccess] = [:]
    var nativeApprovedTools: Set<String> = []

    var toolPolicyEnforcer: any MCPGatewayToolPolicyEnforcing {
        let rules = toolAccessByName.map { toolName, access in
            MCPGatewayToolPolicyRule(
                toolName: toolName,
                access: access,
                nativeApprovalGranted: nativeApprovedTools.contains(Self.normalized(toolName))
            )
        }
        guard toolPolicyRequired || !rules.isEmpty else {
            return AllowingMCPGatewayToolPolicyEnforcer()
        }
        return ConfiguredMCPGatewayToolPolicyEnforcer(
            rules: rules,
            requiresExplicitPolicy: toolPolicyRequired || !rules.isEmpty
        )
    }

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
            case "--endpoint" where index + 1 < arguments.count:
                endpoint = URL(string: arguments[index + 1])
                index += 2
            case "--access-token-env" where index + 1 < arguments.count:
                accessTokenEnvironmentKey = arguments[index + 1]
                index += 2
            case "--gateway-tool-policy-required":
                toolPolicyRequired = true
                index += 1
            case "--gateway-read-tool" where index + 1 < arguments.count:
                recordToolAccess(arguments[index + 1], access: .read)
                index += 2
            case "--gateway-write-tool" where index + 1 < arguments.count:
                recordToolAccess(arguments[index + 1], access: .write)
                index += 2
            case "--gateway-send-tool" where index + 1 < arguments.count:
                recordToolAccess(arguments[index + 1], access: .send)
                index += 2
            case "--gateway-delete-tool" where index + 1 < arguments.count:
                recordToolAccess(arguments[index + 1], access: .delete)
                index += 2
            case "--gateway-admin-tool" where index + 1 < arguments.count:
                recordToolAccess(arguments[index + 1], access: .admin)
                index += 2
            case "--gateway-native-approved-tool" where index + 1 < arguments.count:
                nativeApprovedTools.insert(Self.normalized(arguments[index + 1]))
                index += 2
            default:
                index += 1
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private mutating func recordToolAccess(_ toolName: String, access: MCPGatewayToolAccess) {
        let normalizedName = Self.normalized(toolName)
        guard !normalizedName.isEmpty else { return }
        guard let existing = toolAccessByName[normalizedName] else {
            toolAccessByName[normalizedName] = access
            return
        }
        if access.restrictionRank > existing.restrictionRank {
            toolAccessByName[normalizedName] = access
        }
    }
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension MCPGatewayToolAccess {
    var restrictionRank: Int {
        switch self {
        case .read:
            return 0
        case .write:
            return 1
        case .send:
            return 2
        case .delete:
            return 3
        case .admin:
            return 4
        }
    }
}
