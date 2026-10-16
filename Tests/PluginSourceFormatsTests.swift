import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// A plugin source is a repository with a marketplace file (Claude Code's
/// shape) listing plugins that are ASTRA manifests or Claude-layout plugins.
@Suite("Plugin source formats")
struct PluginSourceFormatsTests {
    @Test("A marketplace file lists in-repository plugins and leaves other sources unread")
    func marketplaceListsEntries() throws {
        let source = MemoryDirectory([
            ".claude-plugin/marketplace.json": #"""
            {"name": "team", "owner": {"name": "Team"}, "plugins": [
              {"name": "jira-tools", "source": "./plugins/jira-tools", "description": "Jira"},
              {"name": "remote", "source": {"source": "github", "repo": "org/remote"}}
            ]}
            """#
        ])
        let marketplace = try #require(try PluginMarketplace.read(from: source))
        #expect(marketplace.name == "team")
        #expect(marketplace.plugins.map(\.name) == ["jira-tools", "remote"])
        #expect(marketplace.plugins.first?.path == "./plugins/jira-tools")
        #expect(marketplace.plugins.last?.path == nil)
    }

    @Test("A Claude-layout plugin brings its skills and MCP servers and reports the rest")
    func claudeLayoutConverts() throws {
        let source = MemoryDirectory([
            "plugins/notes/.claude-plugin/plugin.json": #"{"name": "Team Notes", "version": "1.2.0", "description": "Notes", "author": {"name": "Ana"}}"#,
            "plugins/notes/skills/summarise/SKILL.md": """
            ---
            name: Summarise
            description: Summarise meeting notes
            allowed-tools: Read, Grep
            ---
            Read the notes and write a summary.
            """,
            "plugins/notes/.mcp.json": #"{"mcpServers": {"notes-db": {"command": "notes-mcp", "args": ["--ro"], "env": {"NOTES_TOKEN": "secret"}}}}"#,
            "plugins/notes/agents/reviewer.md": "agent",
            "plugins/notes/hooks/hooks.json": "{}"
        ])
        let plugin = try PluginSourcePluginReader.read(at: "./plugins/notes", in: source)
        let manifest = plugin.manifest
        #expect(manifest.id == "team-notes")
        #expect(manifest.version == "1.2.0")
        #expect(manifest.author == "Ana")
        #expect(manifest.governance?.approvalStatus == .draft)

        let skill = try #require(manifest.components.first { $0.kind == .skill }?.skill)
        #expect(skill.name == "Summarise")
        #expect(skill.allowedTools == ["Read", "Grep"])
        #expect(skill.behaviorInstructions == "Read the notes and write a summary.")

        let mcp = try #require(manifest.components.first { $0.kind == .mcp }?.mcp)
        #expect(mcp.command == "notes-mcp")
        #expect(mcp.environmentKeys == ["NOTES_TOKEN"])
        #expect(manifest.worksOn["cursor_cli"] == .shellOnly)
        #expect(plugin.unsupported == ["1 agent", "hooks"])

        let package = PluginManifestConverter.package(from: manifest)
        #expect(package.skills.count == 1)
        #expect(package.mcpServers.count == 1)
        // Its env keys are declared as an account to fill in, without the
        // file's values, so the MCP key policy does not block Add.
        let settings = try #require(package.connectors.first)
        #expect(settings.credentialHints.map(\.key) == ["NOTES_TOKEN"])
        #expect(!String(describing: package).contains("secret"))
        #expect(MCPEnvironmentKeyPolicy.undeclaredKeys(server: try #require(package.mcpServers.first), package: package).isEmpty)
    }

    @Test("An ASTRA plugin in a source is read through its capability.json")
    func astraPluginReads() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities/jira-workflow.json")
        let source = MemoryDirectory(["plugins/jira/capability.json": try String(contentsOf: url, encoding: .utf8)])
        let plugin = try PluginSourcePluginReader.read(at: "plugins/jira", in: source)
        #expect(plugin.manifest.id == "jira-workflow")
        #expect(plugin.unsupported.isEmpty)
    }

    @Test("A path that leaves the source is refused")
    func escapingPathsAreRefused() {
        let source = MemoryDirectory([:])
        #expect(throws: PluginSourceReadError.unsafePath("../outside")) {
            try PluginSourcePluginReader.read(at: "../outside", in: source)
        }
        #expect(throws: PluginSourceReadError.unsafePath("/etc")) {
            try PluginSourcePluginReader.read(at: "/etc", in: source)
        }
        #expect(throws: PluginSourceReadError.noManifest("plugins/missing")) {
            try PluginSourcePluginReader.read(at: "plugins/missing", in: source)
        }
    }
}

private struct MemoryDirectory: PluginDirectoryReading {
    let files: [String: String]

    init(_ files: [String: String]) { self.files = files }

    func data(at relativePath: String) -> Data? { files[relativePath].map { Data($0.utf8) } }

    func entries(in relativeDirectory: String) -> [String] {
        let prefix = relativeDirectory.isEmpty ? "" : relativeDirectory + "/"
        return Array(Set(files.keys.compactMap { key -> String? in
            guard key.hasPrefix(prefix) else { return nil }
            return key.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }))
    }
}
