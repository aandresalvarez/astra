import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability MCP Readiness Service")
struct CapabilityMCPReadinessServiceTests {
    @Test("missing stdio command creates MCP readiness message")
    func missingStdioCommandCreatesMCPReadinessMessage() {
        let prerequisite = CLIPrerequisite(
            binary: "github-mcp-server",
            displayName: "GitHub MCP runtime",
            purpose: "Launches the GitHub MCP server."
        )
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
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            prerequisiteStatuses: [prerequisite.id: .missingBinary]
        )

        #expect(messages == ["GitHub MCP: command github-mcp-server is not installed."])
    }

    @Test("missing package manager command includes install source")
    func missingPackageManagerCommandIncludesInstallSource() {
        let prerequisite = CLIPrerequisite(
            binary: "npx",
            displayName: "npx runtime",
            purpose: "Launches the GitHub MCP package."
        )
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
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            prerequisiteStatuses: [prerequisite.id: .missingBinary]
        )

        #expect(messages == [
            "GitHub MCP: command npx is not installed. Install npm package @acme/github-mcp@1.0.0 with npx."
        ])
    }

    @Test("missing pipx package manager command includes pipx install source")
    func missingPipxPackageManagerCommandIncludesPipxInstallSource() {
        let prerequisite = CLIPrerequisite(
            binary: "pipx",
            displayName: "pipx runtime",
            purpose: "Launches the Python MCP package."
        )
        let package = PluginPackage(
            id: "python-mcp",
            name: "Python MCP",
            icon: "server.rack",
            description: "Python MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "python",
                    displayName: "Python MCP",
                    transport: .stdio,
                    command: "pipx",
                    arguments: ["run", "example-mcp==2.1.0"],
                    installSource: PluginMCPInstallSource(
                        kind: .pypi,
                        identifier: "example-mcp",
                        version: "2.1.0",
                        installMode: .pipx
                    )
                )
            ],
            templates: [],
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            prerequisiteStatuses: [prerequisite.id: .missingBinary]
        )

        #expect(messages == [
            "Python MCP: command pipx is not installed. Install PyPI package example-mcp==2.1.0 with pipx."
        ])
    }

    @Test("manual install source does not infer package manager from package kind")
    func manualInstallSourceDoesNotInferPackageManagerFromPackageKind() {
        let prerequisite = CLIPrerequisite(
            binary: "manual-mcp",
            displayName: "Manual MCP runtime",
            purpose: "Launches a manually installed MCP package."
        )
        let package = PluginPackage(
            id: "manual-mcp",
            name: "Manual MCP",
            icon: "server.rack",
            description: "Manual MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "manual",
                    displayName: "Manual MCP",
                    transport: .stdio,
                    command: "manual-mcp",
                    installSource: PluginMCPInstallSource(
                        kind: .npm,
                        identifier: "@acme/manual-mcp",
                        installMode: .manual
                    )
                )
            ],
            templates: [],
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            prerequisiteStatuses: [prerequisite.id: .missingBinary]
        )

        #expect(messages == [
            "Manual MCP: command manual-mcp is not installed. Install MCP source @acme/manual-mcp manually."
        ])
    }

    @Test("healthy and remote servers do not create MCP readiness messages")
    func healthyAndRemoteServersDoNotCreateMCPReadinessMessages() {
        let prerequisite = CLIPrerequisite(
            binary: "local-mcp",
            displayName: "Local MCP runtime",
            purpose: "Launches the local MCP server."
        )
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
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let messages = CapabilityMCPReadinessService.readinessMessages(
            for: package,
            prerequisiteStatuses: [prerequisite.id: .healthy(path: "/opt/bin/local-mcp", version: "1.0")]
        )

        #expect(messages.isEmpty)
    }
}
