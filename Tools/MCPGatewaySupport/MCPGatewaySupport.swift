import Foundation
import MCPServerKit

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
    public var allowedTools: [String]
    public var excludedTools: [String]

    public init(
        id: String,
        displayName: String,
        transport: Transport,
        endpoint: URL,
        connectorBindings: [String] = [],
        allowedTools: [String] = [],
        excludedTools: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.endpoint = endpoint
        self.connectorBindings = connectorBindings
        self.allowedTools = allowedTools
        self.excludedTools = excludedTools
    }
}

public struct RemoteMCPGatewayToolPolicy: Equatable {
    public let allowedTools: [String]
    public let excludedTools: [String]

    public init(allowedTools: [String] = [], excludedTools: [String] = []) {
        self.allowedTools = Self.trimmedUnique(allowedTools)
        self.excludedTools = Self.trimmedUnique(excludedTools)
    }

    public func allows(_ toolName: String) -> Bool {
        guard let tool = canonicalToolName(for: toolName) else {
            return false
        }
        return !tool.isEmpty
    }

    public func canonicalToolName(for toolName: String) -> String? {
        let tool = Self.toolKey(toolName)
        guard !tool.isEmpty else { return nil }
        if excludedTools.contains(tool) {
            return nil
        }
        if allowedTools.isEmpty {
            return tool
        }
        return allowedTools.contains(tool) ? tool : nil
    }

    public func filterTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String else {
                return nil
            }
            guard let canonicalName = canonicalToolName(for: name) else {
                return nil
            }
            var normalizedTool = tool
            normalizedTool["name"] = canonicalName
            return normalizedTool
        }
    }

    private static func trimmedUnique(_ tools: [String]) -> [String] {
        var result: [String] = []
        for tool in tools {
            let toolKey = toolKey(tool)
            if !toolKey.isEmpty && !result.contains(toolKey) {
                result.append(toolKey)
            }
        }
        return result
    }

    private static func toolKey(_ value: String) -> String {
        // MCP tool names are case-sensitive; trim whitespace without folding case.
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let normalizedToolName = Self.normalized(toolName)
        guard let rule = rulesByToolName[normalizedToolName] else {
            if requiresExplicitPolicy {
                return .denied("Gateway policy has no classification for tool \(trimmed(toolName)).")
            }
            return .allowed
        }
        guard toolName == rule.toolName else {
            return .denied("Gateway policy tool \(trimmed(toolName)) does not exactly match classified tool \(rule.toolName).")
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
            let candidate = MCPGatewayToolPolicyRule(
                toolName: trimmed(rule.toolName),
                access: rule.access,
                nativeApprovalGranted: rule.nativeApprovalGranted
            )
            guard let existing = result[key] else {
                result[key] = candidate
                return
            }
            if rule.access.restrictionRank > existing.access.restrictionRank {
                result[key] = candidate
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
    private let toolPolicy: RemoteMCPGatewayToolPolicy
    private let toolPolicyEnforcer: any MCPGatewayToolPolicyEnforcing
    private lazy var mcpServer = MCPServer(
        name: "astra-mcp-gateway",
        tools: { [weak self] in
            try self?.listPolicyFilteredTools() ?? []
        },
        handleToolCall: { [weak self] call in
            self?.handleToolCall(call) ?? .error(code: -32000, message: "MCP gateway is unavailable")
        }
    )

    public init(
        server: RemoteMCPServerDescriptor,
        remoteClient: RemoteMCPClient,
        authTokenProvider: MCPGatewayAuthTokenProvider = EmptyMCPGatewayAuthTokenProvider(),
        toolPolicyEnforcer: any MCPGatewayToolPolicyEnforcing = AllowingMCPGatewayToolPolicyEnforcer()
    ) {
        self.server = server
        self.remoteClient = remoteClient
        self.authTokenProvider = authTokenProvider
        self.toolPolicy = RemoteMCPGatewayToolPolicy(
            allowedTools: server.allowedTools,
            excludedTools: server.excludedTools
        )
        self.toolPolicyEnforcer = toolPolicyEnforcer
    }

    public func handleLine(_ line: String) -> String? {
        mcpServer.handleLine(line)
    }

    private func listPolicyFilteredTools() throws -> [[String: Any]] {
        let tools = try remoteClient.listTools(for: server, auth: authContext())
        return toolPolicy.filterTools(tools)
    }

    private func handleToolCall(_ call: MCPToolCall) -> MCPServerReply {
        let requestedToolName = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedToolName.isEmpty else {
            return .error(code: -32602, message: "Unsupported tool")
        }
        guard let toolName = toolPolicy.canonicalToolName(for: requestedToolName) else {
            return .error(code: -32602, message: "Tool is not allowed by ASTRA gateway policy")
        }
        let arguments = call.arguments
        switch toolPolicyEnforcer.decision(forTool: toolName, server: server) {
        case .allowed:
            break
        case .denied(let reason):
            return .result([
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
            return .result([
                "content": [[
                    "type": "text",
                    "text": result.text
                ]],
                "isError": result.isError
            ])
        } catch {
            return .result([
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
            connectorBindings: [],
            allowedTools: options.allowedTools,
            excludedTools: options.excludedTools
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
    var allowedTools: [String] = []
    var excludedTools: [String] = []
    var toolPolicyRequired = false
    var toolRulesByName: [String: MCPGatewayToolPolicyRule] = [:]
    var nativeApprovedTools: Set<String> = []

    var toolPolicyEnforcer: any MCPGatewayToolPolicyEnforcing {
        let rules = toolRulesByName.values.map { rule in
            var candidate = rule
            candidate.nativeApprovalGranted = nativeApprovedTools.contains(Self.normalized(rule.toolName))
            return candidate
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
            case "--allowed-tool" where index + 1 < arguments.count:
                allowedTools.append(arguments[index + 1])
                index += 2
            case "--excluded-tool" where index + 1 < arguments.count:
                excludedTools.append(arguments[index + 1])
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
        let trimmedToolName = trimmed(toolName)
        let normalizedName = Self.normalized(trimmedToolName)
        guard !normalizedName.isEmpty else { return }
        let candidate = MCPGatewayToolPolicyRule(toolName: trimmedToolName, access: access)
        guard let existing = toolRulesByName[normalizedName] else {
            toolRulesByName[normalizedName] = candidate
            return
        }
        if access.restrictionRank > existing.access.restrictionRank {
            toolRulesByName[normalizedName] = candidate
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
