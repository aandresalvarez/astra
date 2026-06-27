import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability MCP Readiness Service")
struct CapabilityMCPReadinessServiceTests {
    @Test("missing stdio command creates MCP readiness message")
    func missingStdioCommandCreatesMCPReadinessMessage() {
        let package = PluginPackage(
            id: "github-mcp",
            name: "GitHub MCP",
            icon: "server.rack",
            description: "GitHub MCP package",
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
                    command: "github-mcp-server"
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            commandStatuses: ["github-mcp-server": .missingBinary]
        )

        #expect(messages == ["GitHub MCP: command github-mcp-server is not installed."])
    }

    @Test("missing package manager command includes install source")
    func missingPackageManagerCommandIncludesInstallSource() {
        let package = PluginPackage(
            id: "github-mcp",
            name: "GitHub MCP",
            icon: "server.rack",
            description: "GitHub MCP package",
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
                    command: "npx",
                    arguments: ["-y", "@acme/github-mcp@1.0.0"],
                    installSource: PluginMCPInstallSource(
                        kind: .npm,
                        identifier: "@acme/github-mcp",
                        version: "1.0.0",
                        installMode: .npx
                    )
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            commandStatuses: ["npx": .missingBinary]
        )

        #expect(messages == [
            "GitHub MCP: command npx is not installed. Install npm package @acme/github-mcp@1.0.0 with npx."
        ])
    }

    @Test("healthy and remote servers do not create MCP readiness messages")
    func healthyAndRemoteServersDoNotCreateMCPReadinessMessages() {
        let package = PluginPackage(
            id: "mixed-mcp",
            name: "Mixed MCP",
            icon: "server.rack",
            description: "Mixed MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "local",
                    displayName: "Local MCP",
                    transport: .stdio,
                    command: "local-mcp"
                ),
                PluginMCPServer(
                    id: "remote",
                    displayName: "Remote MCP",
                    transport: .http,
                    url: URL(string: "https://mcp.example")
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            commandStatuses: ["local-mcp": .healthy(path: "/opt/bin/local-mcp", version: "1.0")]
        )

        #expect(messages.isEmpty)
    }
}
