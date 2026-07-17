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
        #expect(calls.first?.invocationID == "2")

        #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handleLine("   ") == nil)
        #expect(diagnostics.contains(.toolCall("example.echo")))
        #expect(diagnostics.contains(.notification("notifications/initialized")))
    }

    @Test("server encodes shared protocol errors and JSON-RPC ids consistently")
    func serverEncodesSharedProtocolErrorsAndIDsConsistently() throws {
        var handledCalls = 0
        let server = MCPServer(
            name: "astra-test",
            tools: { [] },
            handleToolCall: { _ in
                handledCalls += 1
                return .error(code: -32099, message: "handler failed")
            }
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

        let missingID = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"example.echo","arguments":{}}}"#)))
        #expect(missingID["id"] is NSNull)
        let missingIDError = try #require(missingID["error"] as? [String: Any])
        #expect(missingIDError["code"] as? Int == -32600)

        let unsupportedID = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":{"bad":true},"method":"tools/call","params":{"name":"example.echo","arguments":{}}}"#)))
        #expect(unsupportedID["id"] is NSNull)
        let unsupportedIDError = try #require(unsupportedID["error"] as? [String: Any])
        #expect(unsupportedIDError["code"] as? Int == -32600)

        let booleanID = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{"name":"example.echo","arguments":{}}}"#)))
        #expect(booleanID["id"] is NSNull)
        let booleanIDError = try #require(booleanID["error"] as? [String: Any])
        #expect(booleanIDError["code"] as? Int == -32600)

        let handlerError = try parseJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"example.echo","arguments":{}}}"#)))
        #expect(handlerError["id"] as? Int == 1)
        let error = try #require(handlerError["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32099)
        #expect(error["message"] as? String == "handler failed")
        #expect(handledCalls == 1)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
