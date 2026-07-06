import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("PluginPackage MCP")
struct PluginPackageMCPTests {
    @Test("package decodes without mcp servers")
    func packageDecodesWithoutMCPServers() throws {
        let json = """
        {
          "id": "legacy",
          "name": "Legacy",
          "icon": "puzzlepiece.extension",
          "description": "Legacy package",
          "author": "Tests",
          "category": "Tests",
          "tags": [],
          "version": "1.0.0",
          "skills": [],
          "connectors": [],
          "localTools": [],
          "templates": []
        }
        """

        let package = try JSONDecoder().decode(PluginPackage.self, from: Data(json.utf8))

        #expect(package.mcpServers.isEmpty)
        #expect(package.setupRequirements.isEmpty)
    }

    @Test("package mcp servers round trip")
    func packageMCPServersRoundTrip() throws {
        let package = PluginPackage(
            id: "mcp-package",
            name: "MCP Package",
            icon: "puzzlepiece.extension",
            description: "MCP test",
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
                    arguments: ["stdio"],
                    environmentKeys: ["GITHUB_TOKEN"],
                    allowedTools: ["issues.list"],
                    excludedTools: ["repo.delete"],
                    resourcesEnabled: true,
                    promptsEnabled: true,
                    trustLevel: .high
                )
            ],
            templates: [],
            governance: .builtInApproved(riskLevel: .high)
        )

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)

        #expect(decoded.mcpServers == package.mcpServers)
        #expect(decoded.contentParts.contains("1 MCP server"))
    }

    @Test("setup requirements decode and make package setup gated")
    func setupRequirementsDecodeAndRequireSetup() throws {
        let json = """
        {
          "id": "oauth-package",
          "name": "OAuth Package",
          "icon": "key",
          "description": "OAuth package",
          "author": "Tests",
          "category": "Tests",
          "tags": [],
          "version": "1.0.0",
          "skills": [],
          "connectors": [],
          "localTools": [],
          "mcpServers": [],
          "templates": [],
          "setupRequirements": [
            {
              "id": "provider-oauth",
              "kind": "oauthAccount",
              "displayName": "Provider OAuth",
              "provider": "provider",
              "required": true,
              "notes": "Connect the provider account."
            }
          ]
        }
        """

        let package = try JSONDecoder().decode(PluginPackage.self, from: Data(json.utf8))

        #expect(package.requiresSetup)
        #expect(package.setupRequirements == [
            PluginSetupRequirement(
                id: "provider-oauth",
                kind: .oauthAccount,
                displayName: "Provider OAuth",
                provider: "provider",
                required: true,
                notes: "Connect the provider account."
            )
        ])
        #expect(package.contentParts.contains("1 setup requirement"))
    }

    @Test("mcp install source round trips without changing launch contract")
    func mcpInstallSourceRoundTrips() throws {
        let installSource = PluginMCPInstallSource(
            kind: .npm,
            identifier: "@modelcontextprotocol/server-filesystem",
            version: "0.6.2",
            digest: nil,
            installMode: .npx,
            registryURL: URL(string: "https://registry.npmjs.org/"),
            documentationURL: URL(string: "https://github.com/modelcontextprotocol/servers"),
            packageManagerArguments: ["-y"],
            riskNotes: ["Exact npm package version is pinned."]
        )
        let package = PluginPackage(
            id: "local.filesystem-mcp",
            name: "Filesystem MCP",
            icon: "server.rack",
            description: "Filesystem MCP package",
            author: "Tests",
            category: "MCP",
            tags: ["mcp"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "filesystem",
                    displayName: "Filesystem MCP",
                    transport: .stdio,
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-filesystem@0.6.2", "/tmp"],
                    allowedTools: ["files.read"],
                    trustLevel: .high,
                    installSource: installSource
                )
            ],
            templates: []
        )

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)

        let decodedServer = try #require(decoded.mcpServers.first)
        #expect(decodedServer.command == "npx")
        #expect(decodedServer.arguments == ["-y", "@modelcontextprotocol/server-filesystem@0.6.2", "/tmp"])
        #expect(decodedServer.installSource == installSource)
    }

    @Test("runtime MCP manifest lists only enabled runnable packages")
    @MainActor
    func runtimeMCPManifestListsOnlyEnabledRunnablePackages() {
        let workspace = Workspace(name: "MCP Runtime", primaryPath: "/tmp/mcp-runtime")
        workspace.enabledCapabilityIDs = ["mcp-approved", "mcp-draft"]
        workspace.recordInstalledPlugin(id: "mcp-approved", version: "1.0.0")
        workspace.recordInstalledPlugin(id: "mcp-draft", version: "1.0.0")

        let approved = makeMCPPackage(id: "mcp-approved", governance: .builtInApproved(riskLevel: .high))
        let draft = makeMCPPackage(id: "mcp-draft", governance: .localDraft())

        let manifests = TaskCapabilityResolver.enabledMCPServerManifests(
            for: workspace,
            packages: [draft, approved]
        )

        #expect(manifests.map(\.packageID) == ["mcp-approved"])
        #expect(manifests.first?.id == "github")
        #expect(manifests.first?.allowedTools == ["issues.list"])
        #expect(manifests.first?.trustLevel == "high")
    }
}

private func makeMCPPackage(id: String, governance: CapabilityGovernance) -> PluginPackage {
    PluginPackage(
        id: id,
        name: "MCP Package",
        icon: "puzzlepiece.extension",
        description: "MCP test",
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
                arguments: ["stdio"],
                allowedTools: ["issues.list"],
                excludedTools: ["repo.delete"],
                trustLevel: .high
            )
        ],
        templates: [],
        governance: governance
    )
}
