import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Sources: a git repository or folder with a marketplace file, whose plugins
/// can be added in one step like the built-ins.
@Suite("Plugin sources")
@MainActor
struct PluginSourcesTests {
    @Test("Sources accept https, ssh, owner/repo and absolute folders, and refuse the rest")
    func sourceInputs() {
        #expect(PluginSource.make(from: "https://github.com/org/plugins.git")?.kind == .git)
        #expect(PluginSource.make(from: "git@github.com:org/plugins.git")?.kind == .git)
        #expect(PluginSource.make(from: "org/plugins")?.location == "https://github.com/org/plugins.git")
        #expect(PluginSource.make(from: "org/plugins")?.displayName == "org/plugins")
        #expect(PluginSource.make(from: "/Users/me/plugins")?.kind == .folder)
        for refused in ["", "-uexploit", "file:///tmp/repo", "relative/path/three", "ftp://host/repo"] {
            #expect(PluginSource.make(from: refused) == nil, "accepted \(refused)")
        }
    }

    @Test("A clone is shallow, prompt-free, refuses file transport, and replaces the old one only when complete")
    func fetchClonesSafely() async throws {
        let store = PluginSourceStore(root: try temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let source = try #require(PluginSource.make(from: "https://example.com/org/plugins.git"))
        let runner = FakeGit(writes: ["astra-marketplace.json": #"{"name":"x","plugins":[]}"#])
        try await PluginSourceFetcher(runner: runner, gitPath: { "/usr/bin/git" }).fetch(source, store: store)

        let call = try #require(runner.calls.first)
        #expect(call.args.prefix(2) == ["-c", "protocol.file.allow=never"])
        #expect(call.args.contains("--depth") && call.args.contains("--no-recurse-submodules"))
        #expect(call.args.firstIndex(of: "--")! < call.args.firstIndex(of: source.location)!)
        #expect(call.environment?["GIT_TERMINAL_PROMPT"] == "0")
        #expect(FileManager.default.fileExists(atPath: store.cloneDirectory(for: source).appendingPathComponent("astra-marketplace.json").path))

        let failing = FakeGit(writes: [:], exitCode: 128, stderr: "fatal: repository not found")
        await #expect(throws: PluginSourceFetchError.cloneFailed("fatal: repository not found")) {
            try await PluginSourceFetcher(runner: failing, gitPath: { "/usr/bin/git" }).fetch(source, store: store)
        }
        #expect(FileManager.default.fileExists(atPath: store.cloneDirectory(for: source).path))
    }

    @Test("A folder source lists its plugins as unreviewed drafts, and a built-in ID is refused")
    func folderSourceListsPlugins() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, "astra-marketplace.json", #"""
        {"name": "team", "plugins": [
          {"name": "notes", "source": "./plugins/notes"},
          {"name": "jira", "source": "./plugins/jira"},
          {"name": "elsewhere", "source": {"source": "github", "repo": "org/x"}}
        ]}
        """#)
        try write(folder, "plugins/notes/.claude-plugin/plugin.json", #"{"name": "Team Notes"}"#)
        try write(folder, "plugins/notes/skills/sum/SKILL.md", "---\nname: Summarise\n---\nSummarise.")
        let jira = try String(contentsOf: builtInURL("jira-workflow"), encoding: .utf8)
        try write(folder, "plugins/jira/capability.json", jira)

        let source = try #require(PluginSource.make(from: folder.path))
        let plugins = PluginSourceCatalog.plugins(in: source, store: PluginSourceStore(root: try temporaryDirectory()))
        #expect(plugins.map(\.package.id) == ["team-notes", "jira-workflow"])
        let notes = try #require(plugins.first)
        #expect(notes.package.sourceMetadata?.kind == "plugin-source")
        #expect(notes.package.governance.approvalStatus == .draft)
        #expect(notes.problem == nil)
        #expect(plugins.last?.problem?.contains("built-in") == true)
    }

    @Test("A source plugin whose ID collides with an installed one by case or filename cannot be added")
    func sourceIDCollisionsAreRefused() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, ".claude-plugin/plugin.json", #"{"name": "Team Notes", "version": "1.0.0"}"#)
        try write(folder, "skills/sum/SKILL.md", "---\nname: Summarise\n---\nSummarise.")
        let source = try #require(PluginSource.make(from: folder.path))
        var installed = try #require(PluginCatalog.builtInPackages.first)
        installed.id = "TEAM-NOTES"
        installed.sourceMetadata = .localLibrary()
        let plugins = PluginSourceCatalog.plugins(
            in: source, store: PluginSourceStore(root: try temporaryDirectory()), installedPackages: [installed]
        )
        #expect(plugins.first?.problem != nil)
    }

    @Test("A newer version in a source becomes the Update for the installed source plugin")
    func newerSourceVersionIsTheUpdate() throws {
        let source = try #require(PluginSource.make(from: "/tmp/plugins"))
        var installed = try #require(PluginCatalog.builtInPackages.first)
        installed.id = "team-notes"
        installed.version = "1.0.0"
        installed.sourceMetadata = CapabilitySourceMetadata(id: "plugin-source:x", displayName: "x", kind: "plugin-source", trustLevel: "unreviewed")
        var fetched = installed
        fetched.version = "2.0.0"
        let offered = SourcedPlugin(source: source, package: fetched, unsupported: [], problem: nil)
        #expect(PluginSourceCatalog.updateCandidate(for: installed, among: [offered])?.version == "2.0.0")
        #expect(PluginSourceCatalog.updateCandidate(for: fetched, among: [offered]) == nil)
        var builtIn = installed
        builtIn.sourceMetadata = .builtIn()
        #expect(PluginSourceCatalog.updateCandidate(for: builtIn, among: [offered]) == nil)
    }

    @Test("A symlink inside a source that points outside it is not read")
    func symlinksCannotEscape() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(outside, "secret.json", "{}")
        try write(root, "inside.json", "{}")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.json"),
            withDestinationURL: outside.appendingPathComponent("secret.json")
        )
        let directory = BrokeredPluginDirectory(root: root, kind: .folder)
        #expect(directory.data(at: "inside.json") != nil)
        #expect(directory.data(at: "link.json") == nil)
        #expect(directory.data(at: "../\(outside.lastPathComponent)/secret.json") == nil)
    }

    @Test("Sources are remembered and forgotten")
    func storeRoundTrips() throws {
        let store = PluginSourceStore(root: try temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let source = try #require(PluginSource.make(from: "org/plugins"))
        try store.save([source])
        #expect(store.sources().map(\.id) == [source.id])
        try store.remove(source)
        #expect(store.sources().isEmpty)
    }

    @Test("A plugin from a source adds in one step like a built-in")
    func sourcedPluginAddsInOneStep() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, ".claude-plugin/plugin.json", #"{"name": "Team Notes", "version": "1.0.0"}"#)
        try write(folder, "skills/sum/SKILL.md", "---\nname: Summarise\n---\nSummarise.")
        let source = try #require(PluginSource.make(from: folder.path))
        let plugin = try #require(PluginSourceCatalog.plugins(in: source, store: PluginSourceStore(root: try temporaryDirectory())).first)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspace = Workspace(name: "Sources", primaryPath: "/tmp/plugin-sources-add")
        container.mainContext.insert(workspace)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try CapabilityCatalogActionService(library: CapabilityLibrary(directory: root.appendingPathComponent("lib"))).add(
            plugin.package,
            workspace: workspace,
            modelContext: container.mainContext,
            policyContext: .currentUser(workspace: workspace, approvalRecords: []),
            approvalStore: CapabilityApprovalStore(directory: root.appendingPathComponent("approvals")),
            traceID: "source-add"
        )
        #expect(workspace.capabilityActivation.capabilityIDs == ["team-notes"])
        withExtendedLifetime(container) {}
    }

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ root: URL, _ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func builtInURL(_ id: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities/\(id).json")
    }
}

/// Stands in for `git clone`: writes `writes` into the destination folder.
private final class FakeGit: BinaryRunner, @unchecked Sendable {
    struct Call {
        let args: [String]
        let environment: [String: String]?
    }

    let writes: [String: String]
    let exitCode: Int32
    let stderr: String
    private(set) var calls: [Call] = []

    init(writes: [String: String], exitCode: Int32 = 0, stderr: String = "") {
        self.writes = writes
        self.exitCode = exitCode
        self.stderr = stderr
    }

    func run(path: String, args: [String], timeout: TimeInterval, environment: [String: String]?) async -> RunResult {
        calls.append(Call(args: args, environment: environment))
        if exitCode == 0, let destination = args.last {
            for (file, contents) in writes {
                let url = URL(fileURLWithPath: destination).appendingPathComponent(file)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return RunResult(outcome: .exited(code: exitCode), stdout: "", stderr: stderr)
    }
}
