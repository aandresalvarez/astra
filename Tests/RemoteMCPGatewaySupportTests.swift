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

    @Test("Gateway enforces allowed and excluded tools before authenticated forwarding")
    func gatewayEnforcesToolPolicyBeforeAuthenticatedForwarding() throws {
        let descriptor = RemoteMCPServerDescriptor(
            id: "google_drive",
            displayName: "Google Drive",
            transport: .http,
            endpoint: URL(string: "https://mcp.example.test/google")!,
            connectorBindings: ["google-workspace"],
            allowedTools: ["drive.search"],
            excludedTools: ["drive.files.delete"]
        )
        let remote = RecordingRemoteMCPClient(tools: [
            ["name": "drive.search", "description": "Search fake Drive files."],
            ["name": "drive.files.delete", "description": "Delete a fake Drive file."],
            ["name": "drive.files.export", "description": "Export a fake Drive file."],
            ["description": "Malformed tool without a name."]
        ])
        let gateway = LocalMCPGateway(
            server: descriptor,
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token")
        )

        let list = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["drive.search"])

        let excluded = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"drive.files.delete","arguments":{"id":"abc"}}}"#)))
        let excludedError = try #require(excluded["error"] as? [String: Any])
        #expect(excludedError["code"] as? Int == -32602)

        let unlisted = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"drive.files.export","arguments":{"id":"abc"}}}"#)))
        let unlistedError = try #require(unlisted["error"] as? [String: Any])
        #expect(unlistedError["code"] as? Int == -32602)

        #expect(remote.calledTools.isEmpty)
        #expect(remote.authHeaders == ["Bearer secret-access-token"])
    }

    @Test("Gateway rejects case variants before authenticated forwarding")
    func gatewayRejectsCaseVariantsBeforeAuthenticatedForwarding() throws {
        let descriptor = RemoteMCPServerDescriptor(
            id: "google_drive",
            displayName: "Google Drive",
            transport: .http,
            endpoint: URL(string: "https://mcp.example.test/google")!,
            connectorBindings: ["google-workspace"],
            allowedTools: ["drive.search"]
        )
        let remote = RecordingRemoteMCPClient()
        let gateway = LocalMCPGateway(
            server: descriptor,
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token")
        )

        let call = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":" Drive.Search ","arguments":{"query":"budget"}}}"#)))
        let error = try #require(call["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        #expect(remote.calledTools.isEmpty)
    }

    @Test("Gateway preserves case-sensitive tool names after exact policy match")
    func gatewayPreservesCaseSensitiveToolNamesAfterExactPolicyMatch() throws {
        let descriptor = RemoteMCPServerDescriptor(
            id: "custom_export",
            displayName: "Custom Export",
            transport: .http,
            endpoint: URL(string: "https://mcp.example.test/custom")!,
            connectorBindings: ["custom"],
            allowedTools: [" DATA_EXPORT_v2 "],
            excludedTools: ["data_export_v2"]
        )
        let remote = RecordingRemoteMCPClient(tools: [
            ["name": "DATA_EXPORT_v2", "description": "Export data."],
            ["name": "data_export_v2", "description": "Different case-sensitive tool."],
            ["name": "Data_Export_v2", "description": "Another different case-sensitive tool."]
        ])
        let gateway = LocalMCPGateway(
            server: descriptor,
            remoteClient: remote,
            authTokenProvider: StaticGatewayTokenProvider(token: "secret-access-token")
        )

        let list = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["DATA_EXPORT_v2"])

        let allowed = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":" DATA_EXPORT_v2 ","arguments":{"query":"budget"}}}"#)))
        let allowedResult = try #require(allowed["result"] as? [String: Any])
        #expect(allowedResult["isError"] as? Bool == false)
        #expect(remote.calledTools == ["DATA_EXPORT_v2"])

        let excluded = try parseJSON(try #require(gateway.handleLine(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"data_export_v2","arguments":{"query":"budget"}}}"#)))
        let excludedError = try #require(excluded["error"] as? [String: Any])
        #expect(excludedError["code"] as? Int == -32602)
        #expect(remote.calledTools == ["DATA_EXPORT_v2"])
    }

    @Test("Tool policy normalizes whitespace without changing case")
    func toolPolicyNormalizesWhitespaceWithoutChangingCase() {
        let policy = RemoteMCPGatewayToolPolicy(
            allowedTools: [" DATA_EXPORT_v2 ", "DATA_EXPORT_v2", "data_export_v2"],
            excludedTools: [" Admin.Delete "]
        )

        #expect(policy.allowedTools == ["DATA_EXPORT_v2", "data_export_v2"])
        #expect(policy.excludedTools == ["Admin.Delete"])
        #expect(policy.canonicalToolName(for: " DATA_EXPORT_v2 ") == "DATA_EXPORT_v2")
        #expect(policy.canonicalToolName(for: "data_export_v2") == "data_export_v2")
        #expect(policy.canonicalToolName(for: "Data_Export_v2") == nil)
        #expect(policy.canonicalToolName(for: " Admin.Delete ") == nil)
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

private final class RecordingRemoteMCPClient: RemoteMCPClient {
    var listedServers: [RemoteMCPServerDescriptor] = []
    var calledTools: [String] = []
    var calledArguments: [[String: Any]] = []
    var authHeaders: [String] = []
    var tools: [[String: Any]]

    init(tools: [[String: Any]] = [[
        "name": "drive.search",
        "description": "Search fake Drive files.",
        "inputSchema": [
            "type": "object",
            "properties": ["query": ["type": "string"]],
            "required": ["query"],
            "additionalProperties": false
        ]
    ]]) {
        self.tools = tools
    }

    func listTools(
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> [[String: Any]] {
        listedServers.append(server)
        if let header = auth.authorizationHeader {
            authHeaders.append(header)
        }
        return tools
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
