import Testing
@testable import ASTRA

@Suite("MCP Install Chat Command")
struct MCPInstallChatCommandTests {
    @Test("detects explicit mcp install command")
    func detectsExplicitMCPInstallCommand() throws {
        let request = try #require(MCPInstallChatCommand.installRequest(input: "/mcp npx -y @acme/mcp@1.0.0"))

        #expect(request.intent.command == "npx")
        #expect(request.intent.installSource?.identifier == "@acme/mcp")
    }

    @Test("detects pasted npx mcp command without slash prefix")
    func detectsPastedNPXMCPCommandWithoutSlashPrefix() throws {
        let request = try #require(MCPInstallChatCommand.installRequest(input: "npx -y @acme/mcp-server@1.0.0"))

        #expect(request.intent.installSource?.kind == .npm)
    }

    @Test("detects pasted uvx mcp command without slash prefix")
    func detectsPastedUVXMCPCommandWithoutSlashPrefix() throws {
        let request = try #require(MCPInstallChatCommand.installRequest(input: "uvx mcp-server-acme==1.0.0"))

        #expect(request.intent.installSource?.kind == .pypi)
    }

    @Test("ignores ordinary user requests")
    func ignoresOrdinaryUserRequests() {
        #expect(MCPInstallChatCommand.installRequest(input: "please write tests for the app") == nil)
    }
}
