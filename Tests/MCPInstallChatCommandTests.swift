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

    @Test("explicit malformed mcpServers JSON returns a clear failure")
    func explicitMalformedMCPServersJSONReturnsClearFailure() {
        let json = #"{ "mcpServers": { "broken": { "args": ["-y", "@acme/missing-command"] } } }"#

        let result = MCPInstallChatCommand.installResult(input: "/mcp \(json)")

        guard case .failure(let failure) = result else {
            Issue.record("Expected malformed explicit mcpServers JSON to produce a clear failure")
            return
        }
        #expect(failure.message.contains("/mcp"))
        #expect(failure.message.contains("every declared server"))
        #expect(MCPInstallChatCommand.installRequest(input: "/mcp \(json)") == nil)
    }

    @Test("turn outcome carries parse failure without requiring workspace")
    func turnOutcomeCarriesParseFailureWithoutRequiringWorkspace() throws {
        let json = #"{ "mcpServers": { "broken": { "args": ["-y", "@acme/missing-command"] } } }"#
        let outcome = try #require(MCPInstallChatCommand.installTurnOutcome(input: "/mcp \(json)", hasWorkspace: false))

        #expect(outcome.request == nil)
        #expect(outcome.assistantMessage.contains("could not parse"))
    }

    @Test("turn outcome asks for workspace before opening install review")
    func turnOutcomeAsksForWorkspaceBeforeOpeningInstallReview() throws {
        let outcome = try #require(MCPInstallChatCommand.installTurnOutcome(input: "/mcp npx -y @acme/mcp", hasWorkspace: false))

        #expect(outcome.request == nil)
        #expect(outcome.assistantMessage.contains("workspace-scoped"))
    }

    @Test("turn outcome opens install review when workspace exists")
    func turnOutcomeOpensInstallReviewWhenWorkspaceExists() throws {
        let outcome = try #require(MCPInstallChatCommand.installTurnOutcome(input: "/mcp npx -y @acme/mcp", hasWorkspace: true))

        #expect(outcome.request?.intent.installSource?.identifier == "@acme/mcp")
        #expect(outcome.assistantMessage.contains("Review it"))
    }

    @Test("detects pasted npx mcp command without slash prefix")
    func detectsPastedNPXMCPCommandWithoutSlashPrefix() throws {
        let request = try #require(MCPInstallChatCommand.installRequest(input: "npx -y @acme/mcp-server@1.0.0"))

        #expect(request.intent.installSource?.kind == .npm)
    }

    @Test("detects Audity generator as setup request")
    func detectsAudityGeneratorAsSetupRequest() throws {
        let request = try #require(MCPInstallChatCommand.installRequest(input: "npx @auditynow/connect --generate"))

        #expect(request.intent.kind == .setupCommand)
        #expect(request.intent.setupCommand?.purpose == .generateConfig)
        #expect(request.intent.serverSpecs.isEmpty)
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
