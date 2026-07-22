import Foundation
import Testing
@testable import MCPServerKit

@Suite("MCP Server Kit")
struct MCPServerKitTests {
    @Test("server owns JSON-RPC protocol flow and delegates only tool handling")
    func serverOwnsProtocolFlowAndDelegatesOnlyToolHandling() throws {
        var calls: [MCPToolCall] = []
        var diagnostics: [MCPServerDiagnostic] = []
        let server = MCPServer(
            name: "astra-test",
            version: "9.9.9",
            sessionID: "test-session",
            tools: {
                [[
                    "name": "example.echo",
                    "description": "Echo input.",
                    "inputSchema": ["type": "object"]
                ]]
            },
            diagnostics: { diagnostics.append($0) },
            handleToolCall: { call in
                calls.append(call)
                return .result([
                    "content": [[
                        "type": "text",
                        "text": "ran \(call.name)"
                    ]],
                    "isError": false
                ])
            }
        )

        let initialize = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)))
        let initializeResult = try #require(initialize["result"] as? [String: Any])
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "astra-test")
        #expect(serverInfo["version"] as? String == "9.9.9")
        #expect((initializeResult["capabilities"] as? [String: Any])?["tools"] != nil)

        let list = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":"list-1","method":"tools/list"}"#)))
        #expect(list["id"] as? String == "list-1")
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "example.echo")

        let call = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"example.echo","arguments":{"message":"hello"}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        #expect(callResult["isError"] as? Bool == false)
        #expect(calls.map(\.name) == ["example.echo"])
        #expect(calls.first?.arguments["message"] as? String == "hello")
        #expect(calls.first?.invocationID == "session-base64:dGVzdC1zZXNzaW9u|number:2")

        #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handleLine("   ") == nil)
        #expect(diagnostics.contains(.toolCall("example.echo")))
        #expect(diagnostics.contains(.notification("notifications/initialized")))
    }

    @Test("tools/call rejects missing null boolean and unsupported ids before delegation")
    func toolCallsRequireSupportedRequestIDs() throws {
        var calls: [MCPToolCall] = []
        let server = MCPServer(
            name: "astra-test",
            sessionID: "domain-session",
            tools: { [] },
            handleToolCall: { call in
                calls.append(call)
                return .result(["content": []])
            }
        )
        let lines = [
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"side.effect"}}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{"name":"side.effect"}}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{"name":"side.effect"}}"#,
            #"{"jsonrpc":"2.0","id":{"unsupported":1},"method":"tools/call","params":{"name":"side.effect"}}"#
        ]

        for line in lines {
            let response = try parseJSON(try #require(server.handleLine(line)))
            #expect(response["id"] is NSNull)
            let error = try #require(response["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32600)
        }
        #expect(calls.isEmpty)
    }

    @Test("string and numeric request ids have separate invocation domains")
    func requestIDDomainsAreSeparate() throws {
        var invocationIDs: [String] = []
        let server = MCPServer(
            name: "astra-test",
            sessionID: "domain-session",
            tools: { [] },
            handleToolCall: { call in
                invocationIDs.append(call.invocationID)
                return .result(["content": []])
            }
        )

        _ = server.handleLine(#"{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"side.effect"}}"#)
        _ = server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"side.effect"}}"#)

        #expect(invocationIDs == [
            "session-base64:ZG9tYWluLXNlc3Npb24=|string-base64:MQ==",
            "session-base64:ZG9tYWluLXNlc3Npb24=|number:1"
        ])
        #expect(Set(invocationIDs).count == 2)
    }

    @Test("reused JSON-RPC ids are distinct across MCP sessions")
    func reusedRequestIDsAreSessionScoped() {
        var invocationIDs: [String] = []
        func makeServer(sessionID: String) -> MCPServer {
            MCPServer(
                name: "astra-test",
                sessionID: sessionID,
                tools: { [] },
                handleToolCall: { call in
                    invocationIDs.append(call.invocationID)
                    return .result(["content": []])
                }
            )
        }
        let first = makeServer(sessionID: "connection-one")
        let second = makeServer(sessionID: "connection-two")

        _ = first.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"side.effect"}}"#)
        _ = second.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"side.effect"}}"#)

        #expect(invocationIDs.count == 2)
        #expect(Set(invocationIDs).count == 2)
        #expect(invocationIDs.allSatisfy { $0.hasSuffix("|number:1") })
    }

    @Test("server encodes shared protocol errors and JSON-RPC ids consistently")
    func serverEncodesSharedProtocolErrorsAndIDsConsistently() throws {
        let server = MCPServer(
            name: "astra-test",
            tools: { [] },
            handleToolCall: { _ in .error(code: -32099, message: "handler failed") }
        )

        let invalid = try parseJSON(try #require(server.handleLine("{")))
        #expect(invalid["id"] is NSNull)
        let invalidError = try #require(invalid["error"] as? [String: Any])
        #expect(invalidError["code"] as? Int == -32700)

        let unsupported = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":"u-1","method":"resources/list"}"#)))
        #expect(unsupported["id"] as? String == "u-1")
        let unsupportedError = try #require(unsupported["error"] as? [String: Any])
        #expect(unsupportedError["code"] as? Int == -32601)
        #expect((unsupportedError["message"] as? String)?.contains("Unsupported method resources/list") == true)

        let missingTool = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"arguments":{}}}"#)))
        let missingToolError = try #require(missingTool["error"] as? [String: Any])
        #expect(missingToolError["code"] as? Int == -32602)
        #expect(missingToolError["message"] as? String == "Unsupported tool")

        let invalidID = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":{"bad":true},"method":"tools/call","params":{"name":"example.echo","arguments":{}}}"#)))
        #expect(invalidID["id"] is NSNull)
        let error = try #require(invalidID["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32600)
        #expect(error["message"] as? String == "tools/call requires a string or numeric request id")
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
