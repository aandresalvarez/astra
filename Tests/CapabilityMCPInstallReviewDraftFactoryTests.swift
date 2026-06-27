import Testing
@testable import ASTRA

@Suite("Capability MCP install review draft factory")
struct CapabilityMCPInstallReviewDraftFactoryTests {
    @Test("single server config preserves declared environment keys in editable draft")
    func singleServerConfigPreservesDeclaredEnvironmentKeysInEditableDraft() throws {
        let json = """
        {
          "mcpServers": {
            "github": {
              "type": "stdio",
              "command": "npx",
              "args": ["-y", "@acme/github-mcp@1.0.0"],
              "env": {
                "GITHUB_TOKEN": "ghp_inline_secret"
              }
            }
          }
        }
        """
        let intent = try #require(MCPInstallIntentParser.parse(json))

        let state = CapabilityMCPInstallReviewDraftFactory.draftState(from: intent)
        let server = try state.draft.makeServer(declaredEnvironmentKeys: state.declaredEnvironmentKeys)

        #expect(state.declaredEnvironmentKeys == ["GITHUB_TOKEN"])
        #expect(state.draft.environmentKeysText == "GITHUB_TOKEN")
        #expect(server.environmentKeys == ["GITHUB_TOKEN"])
        #expect(server.arguments == ["-y", "@acme/github-mcp@1.0.0"])
    }
}
