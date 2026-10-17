import Testing
import ASTRACore
@testable import ASTRA

@Suite("Codex MCP config renderer")
struct CodexMCPConfigRendererTests {
    @Test("Tool allowlists use supported Codex fields without changing exclusions or approvals")
    func toolAllowlistUsesSupportedFields() throws {
        let server = PluginMCPServer(
            id: "files",
            displayName: "Files",
            transport: .stdio,
            command: "/usr/bin/true",
            allowedTools: ["write_file", "read_file"],
            excludedTools: ["write_file"],
            trustLevel: .high
        )
        let arguments = CodexMCPConfigRenderer.configArguments(servers: [
            MCPRuntimeProjection.ResolvedServer(packageID: "files", server: server)
        ])
        let config = try #require(arguments.last)

        #expect(config.contains("enabled_tools=[\"read_file\",\"write_file\"]"))
        #expect(config.contains("disabled_tools=[\"write_file\"]"))
        #expect(config.contains("default_tools_approval_mode=\"approve\""))
        #expect(!config.contains("default_tools_enabled"))
    }

    @Test("An unrestricted server does not acquire an empty tool allowlist")
    func unrestrictedServerKeepsDefaultToolVisibility() throws {
        let server = PluginMCPServer(
            id: "files",
            displayName: "Files",
            transport: .stdio,
            command: "/usr/bin/true"
        )
        let config = try #require(CodexMCPConfigRenderer.configArguments(servers: [
            MCPRuntimeProjection.ResolvedServer(packageID: "files", server: server)
        ]).last)

        #expect(!config.contains("enabled_tools="))
        #expect(!config.contains("default_tools_enabled"))
    }
}
