import Foundation
import Testing
@testable import MCPGatewaySupport

@Suite("Remote MCP Gateway Support")
struct RemoteMCPGatewaySupportTests {
    @Test("Gateway lists remote tools and forwards tool calls through auth interface")
    func gatewayListsAndCallsFakeRemoteBackend() throws {
        let descriptor = RemoteMCPServerDescriptor(
            id: "google_drive",
            displayName: "Google Drive",
            transport: .http,
            endpoint: URL(string: "https://mcp.example.test/google")!,
            connectorBindings: ["google-workspace"]
        )
        let remote = RecordingRemoteMCPClient()
        let gateway = LocalMCPGateway(
            server: descriptor,
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token")
        )

        let initialize = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)))
        let initializeResult = try #require(initialize["result"] as? [String: Any])
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "astra-mcp-gateway")

        let list = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["drive.search"])
        #expect(remote.listedServers.map(\.id) == ["google_drive"])
        #expect(remote.authHeaders == ["Bearer secret-access-token"])

        let call = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"drive.search","arguments":{"query":"budget"}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        #expect(callResult["isError"] as? Bool == false)
        let content = try #require(callResult["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "remote result for budget")
        #expect(remote.calledTools == ["drive.search"])
        #expect(remote.calledArguments.first?["query"] as? String == "budget")

        let listJSON = try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#))
        #expect(!listJSON.contains("secret-access-token"))
    }

    @Test("Gateway blocks write tools before bearer-token forwarding without native approval")
    func gatewayBlocksWriteToolsWithoutNativeApproval() throws {
        let remote = RecordingRemoteMCPClient()
        let gateway = LocalMCPGateway(
            server: googleDriveDescriptor(),
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token"),
            toolPolicyEnforcer: ConfiguredMCPGatewayToolPolicyEnforcer(rules: [
                MCPGatewayToolPolicyRule(toolName: "create_file", access: .write)
            ])
        )

        let call = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"create_file","arguments":{"name":"budget.txt"}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])

        #expect(callResult["isError"] as? Bool == true)
        #expect((content.first?["text"] as? String)?.contains("Native approval required") == true)
        #expect(remote.calledTools.isEmpty)
        #expect(remote.authHeaders.isEmpty)
    }

    @Test("Gateway requires explicit policy when any classification rule is configured")
    func gatewayRequiresExplicitPolicyWhenClassificationsAreConfigured() throws {
        let remote = RecordingRemoteMCPClient()
        let options = GatewayCommandOptions(arguments: [
            "--gateway-read-tool", "search_files"
        ])
        let gateway = LocalMCPGateway(
            server: googleDriveDescriptor(),
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token"),
            toolPolicyEnforcer: options.toolPolicyEnforcer
        )

        let call = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"create_file","arguments":{"query":"budget"}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])

        #expect(callResult["isError"] as? Bool == true)
        #expect((content.first?["text"] as? String)?.contains("no classification") == true)
        #expect(remote.calledTools.isEmpty)
        #expect(remote.authHeaders.isEmpty)
    }

    @Test("Gateway resolves duplicate normalized rules to the most restrictive access")
    func gatewayDuplicateRulesUseMostRestrictiveAccess() throws {
        let remote = RecordingRemoteMCPClient()
        let gateway = LocalMCPGateway(
            server: googleDriveDescriptor(),
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token"),
            toolPolicyEnforcer: ConfiguredMCPGatewayToolPolicyEnforcer(rules: [
                MCPGatewayToolPolicyRule(toolName: "Create_File", access: .read),
                MCPGatewayToolPolicyRule(toolName: "create_file", access: .write)
            ])
        )

        let call = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"CREATE_FILE","arguments":{"query":"budget"}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])

        #expect(callResult["isError"] as? Bool == true)
        #expect((content.first?["text"] as? String)?.contains("Native approval required") == true)
        #expect(remote.calledTools.isEmpty)
        #expect(remote.authHeaders.isEmpty)
    }

    @Test("Gateway forwards read tools and explicitly approved write tools")
    func gatewayForwardsReadAndApprovedWriteTools() throws {
        let remote = RecordingRemoteMCPClient()
        let gateway = LocalMCPGateway(
            server: googleDriveDescriptor(),
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token"),
            toolPolicyEnforcer: ConfiguredMCPGatewayToolPolicyEnforcer(rules: [
                MCPGatewayToolPolicyRule(toolName: "search_files", access: .read),
                MCPGatewayToolPolicyRule(toolName: "create_file", access: .write, nativeApprovalGranted: true)
            ])
        )

        _ = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"search_files","arguments":{"query":"budget"}}}"#)))
        _ = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"create_file","arguments":{"query":"budget"}}}"#)))

        #expect(remote.calledTools == ["search_files", "create_file"])
        #expect(remote.authHeaders == ["Bearer secret-access-token", "Bearer secret-access-token"])
    }

    @Test("Environment token provider reads the gateway process token")
    func environmentTokenProvider() throws {
        let provider = EnvironmentMCPGatewayAuthTokenProvider(
            variableName: "ASTRA_TEST_GATEWAY_TOKEN",
            environment: ["ASTRA_TEST_GATEWAY_TOKEN": " process-token "]
        )

        let token = try provider.accessToken(for: RemoteMCPServerDescriptor(
            id: "google_workspace_gmail",
            displayName: "Gmail",
            transport: .http,
            endpoint: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!
        ))

        #expect(token == "process-token")
    }
}

private func googleDriveDescriptor() -> RemoteMCPServerDescriptor {
    RemoteMCPServerDescriptor(
        id: "google_workspace_drive",
        displayName: "Google Drive",
        transport: .http,
        endpoint: URL(string: "https://mcp.example.test/google")!,
        connectorBindings: ["google-workspace"]
    )
}

private final class RecordingRemoteMCPClient: RemoteMCPClient {
    var listedServers: [RemoteMCPServerDescriptor] = []
    var calledTools: [String] = []
    var calledArguments: [[String: Any]] = []
    var authHeaders: [String] = []

    func listTools(
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> [[String: Any]] {
        listedServers.append(server)
        if let header = auth.authorizationHeader {
            authHeaders.append(header)
        }
        return [[
            "name": "drive.search",
            "description": "Search fake Drive files.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
                "additionalProperties": false
            ]
        ]]
    }

    func callTool(
        _ name: String,
        arguments: [String: Any],
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> RemoteMCPToolResult {
        calledTools.append(name)
        calledArguments.append(arguments)
        if let header = auth.authorizationHeader {
            authHeaders.append(header)
        }
        return RemoteMCPToolResult(text: "remote result for \(arguments["query"] as? String ?? "")", isError: false)
    }
}

private struct StaticGatewayTokenProvider: MCPGatewayAuthTokenProvider {
    var token: String?

    func accessToken(for server: RemoteMCPServerDescriptor) throws -> String? {
        token
    }
}

private func parseJSON(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
