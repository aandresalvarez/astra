import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Package Resource Summary")
struct CapabilityPackageResourceSummaryTests {
    @Test("counts and names include MCP servers")
    func countsAndNamesIncludeMCPServers() {
        let package = PluginPackage(
            id: "mcp-visible",
            name: "MCP Visible",
            icon: "server.rack",
            description: "Visible MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "github",
                    displayName: "GitHub MCP",
                    transport: .stdio,
                    command: "github-mcp-server",
                    allowedTools: ["issues.list"]
                )
            ],
            templates: [],
            browserAdapters: ["github"],
            governance: .builtInApproved(riskLevel: .high)
        )

        let summary = CapabilityPackageResourceSummary(package: package)

        #expect(summary.declaredResourceCount == 2)
        #expect(summary.mcpServerNames == ["GitHub MCP"])
        #expect(summary.contentSummary(separator: ", ") == "1 MCP server, 1 browser adapter")
        #expect(summary.contentSummary(separator: " · ") == "1 MCP server · 1 browser adapter")
        #expect(summary.resourceCountsForCacheSignature == [0, 0, 0, 1, 0, 1, 0])
    }

    @Test("empty package reports no declared resources")
    func emptyPackageReportsNoDeclaredResources() {
        let package = PluginPackage(
            id: "empty",
            name: "Empty",
            icon: "puzzlepiece.extension",
            description: "",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )

        let summary = CapabilityPackageResourceSummary(package: package)

        #expect(summary.declaredResourceCount == 0)
        #expect(summary.contentSummary(separator: " · ") == "No declared resources")
    }
}
