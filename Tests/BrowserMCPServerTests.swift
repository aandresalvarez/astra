import Foundation
import Testing
import ASTRACore

@Suite("Browser MCP Server")
struct BrowserMCPServerTests {
    @Test("Browser MCP server exposes and runs browser command")
    func browserMCPServerExposesAndRunsBrowserCommand() async throws {
        let executor = RecordingBrowserMCPExecutor(output: #"{"ok":true}"#)
        let server = BrowserMCPServer(executor: executor)

        let initialize = try parseJSON(try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)))
        let initializeResult = try #require(initialize["result"] as? [String: Any])
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "astra-browser")

        let list = try parseJSON(try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "browser")

        let call = try parseJSON(try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser","arguments":{"command":"read-page","arguments":["--format","markdown","--limit","50000"]}}}"#)))
        let callResult = try #require(call["result"] as? [String: Any])
        #expect(callResult["isError"] as? Bool == false)
        let content = try #require(callResult["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == #"{"ok":true}"#)
        #expect(executor.commands == [["read-page", "--format", "markdown", "--limit", "50000"]])
    }

    @Test("Browser MCP server rejects non-string arguments")
    func browserMCPServerRejectsNonStringArguments() async throws {
        let executor = RecordingBrowserMCPExecutor(output: #"{"ok":true}"#)
        let server = BrowserMCPServer(executor: executor)

        let response = try parseJSON(try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"browser","arguments":{"command":"read-page","arguments":[7]}}}"#)))
        let error = try #require(response["error"] as? [String: Any])

        #expect(error["code"] as? Int == -32602)
        #expect((error["message"] as? String)?.contains("array of strings") == true)
        #expect(executor.commands.isEmpty)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class RecordingBrowserMCPExecutor: BrowserMCPCommandExecutor {
    var commands: [[String]] = []
    let output: String

    init(output: String) {
        self.output = output
    }

    func runBrowserCommand(arguments: [String]) async throws -> String {
        commands.append(arguments)
        return output
    }
}
