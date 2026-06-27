import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability MCP Server Draft")
struct CapabilityMCPServerDraftTests {
    @Test("stdio draft builds governed server with declared env keys")
    func stdioDraftBuildsGovernedServerWithDeclaredEnvKeys() throws {
        var draft = CapabilityMCPServerDraft()
        draft.serverID = "github"
        draft.displayName = " GitHub MCP "
        draft.transport = .stdio
        draft.command = " github-mcp-server "
        draft.argumentsText = "stdio\n--read-only"
        draft.environmentKeysText = "GITHUB_TOKEN"
        draft.connectorBindingsText = "github"
        draft.allowedToolsText = "issues.list\npull_requests.read"
        draft.excludedToolsText = "repo.delete"
        draft.resourcesEnabled = true
        draft.promptsEnabled = true
        draft.trustLevel = .high

        let server = try draft.makeServer(declaredEnvironmentKeys: ["GITHUB_TOKEN"])

        #expect(server.id == "github")
        #expect(server.displayName == "GitHub MCP")
        #expect(server.transport == .stdio)
        #expect(server.command == "github-mcp-server")
        #expect(server.arguments == ["stdio", "--read-only"])
        #expect(server.environmentKeys == ["GITHUB_TOKEN"])
        #expect(server.connectorBindings == ["github"])
        #expect(server.allowedTools == ["issues.list", "pull_requests.read"])
        #expect(server.excludedTools == ["repo.delete"])
        #expect(server.resourcesEnabled)
        #expect(server.promptsEnabled)
        #expect(server.trustLevel == .high)
    }

    @Test("draft rejects undeclared environment keys")
    func draftRejectsUndeclaredEnvironmentKeys() {
        var draft = CapabilityMCPServerDraft()
        draft.serverID = "leaky"
        draft.displayName = "Leaky MCP"
        draft.transport = .stdio
        draft.command = "leaky-mcp"
        draft.environmentKeysText = "AWS_SECRET_ACCESS_KEY"

        #expect(throws: CapabilityMCPServerDraft.ValidationError.self) {
            try draft.makeServer(declaredEnvironmentKeys: [])
        }
    }

    @Test("draft rejects unsafe remote urls")
    func draftRejectsUnsafeRemoteURLs() {
        var draft = CapabilityMCPServerDraft()
        draft.serverID = "remote"
        draft.displayName = "Remote MCP"
        draft.transport = .http
        draft.urlText = "http://example.com/mcp"

        #expect(throws: CapabilityMCPServerDraft.ValidationError.self) {
            try draft.makeServer()
        }
    }

    @Test("draft preserves install source metadata")
    func draftPreservesInstallSourceMetadata() throws {
        var draft = CapabilityMCPServerDraft()
        draft.serverID = "github"
        draft.displayName = "GitHub MCP"
        draft.transport = .stdio
        draft.command = "npx"
        draft.argumentsText = "-y\n@acme/github-mcp@1.0.0"
        draft.installSource = PluginMCPInstallSource(
            kind: .npm,
            identifier: "@acme/github-mcp",
            version: "1.0.0",
            installMode: .npx
        )

        let server = try draft.makeServer()

        #expect(server.installSource?.identifier == "@acme/github-mcp")
        #expect(server.installSource?.version == "1.0.0")
    }
}
