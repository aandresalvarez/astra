import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The Plugins 2.0 manifest projects into today's packages losslessly, so the
/// library, installer and runtime keep working unchanged underneath it.
@Suite("Plugin manifest")
struct PluginManifestTests {
    @Test("Every built-in capability survives package → manifest → package unchanged")
    func builtInsRoundTripLosslessly() throws {
        let files = try builtInFiles()
        #expect(files.count >= 10)
        for file in files {
            let original = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
            let manifest = PluginManifestConverter.manifest(from: original)
            let restored = PluginManifestConverter.package(from: manifest)
            #expect(try canonical(restored) == canonical(original), "\(file.lastPathComponent) changed in the round trip")
        }
    }

    @Test("A manifest survives JSON and decodes back into the same package")
    func manifestJSONRoundTrips() throws {
        for file in try builtInFiles() {
            let original = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
            let data = try JSONEncoder().encode(PluginManifestConverter.manifest(from: original))
            #expect(PluginManifestConverter.isManifest(data))
            #expect(try canonical(PluginManifestConverter.decodePackage(from: data)) == canonical(original))
        }
        let packageData = try Data(contentsOf: try builtInFiles()[0])
        #expect(!PluginManifestConverter.isManifest(packageData))
    }

    @Test("A CLI dependency becomes setup rows with check, connect, repair and install")
    func cliPrerequisitesBecomeSetupComponents() throws {
        let manifest = PluginManifestConverter.manifest(from: try builtIn("gcloud-workflow"))
        let setup = manifest.components.filter { $0.kind == .setup }
        let cli = try #require(setup.first { $0.name == "Google Cloud CLI" })
        #expect(cli.setup.check == PluginSetupStep(kind: .exec, binary: "gcloud", arguments: ["--version"]))
        #expect(cli.setup.install?.url?.absoluteString == "https://cloud.google.com/sdk/docs/install")

        let login = try #require(setup.first { $0.name == "Google Cloud login" })
        #expect(login.setup.check?.expect == "stdoutNonEmpty")
        #expect(login.setup.connect?.kind == .terminal)
        #expect(login.setup.connect?.command == "gcloud auth login")
        #expect(login.setup.repair == login.setup.connect)
        #expect(manifest.components.filter { $0.kind == .tool }.map(\.name).contains("gcloud"))
    }

    @Test("A connector's setup asks for its credentials, and MCP plugins are shell-only where MCP does not reach")
    func connectorSetupAndWorksOn() throws {
        let jira = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        let connector = try #require(jira.components.first { $0.kind == .connector })
        #expect(connector.setup.connect?.kind == .credentialForm)
        #expect(connector.setup.connect?.fields?.isEmpty == false)
        #expect(jira.worksOn["cursor_cli"] == .full)

        let workspace = PluginManifestConverter.manifest(from: try builtIn("google-workspace"))
        #expect(workspace.components.filter { $0.kind == .mcp }.count == 3)
        #expect(workspace.worksOn["claude_code"] == .full)
        #expect(workspace.worksOn["cursor_cli"] == .shellOnly)
        #expect(workspace.worksOn["antigravity_cli"] == .shellOnly)
    }

    @Test("A manifest whose setup steps the package can't carry is refused, not installed without them")
    func unrepresentableSetupIsRefused() throws {
        var manifest = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        let skillIndex = try #require(manifest.components.firstIndex { $0.kind == .skill })
        manifest.components[skillIndex].setup.verify = PluginSetupStep(kind: .exec, binary: "jira", arguments: ["me"])
        let data = try JSONEncoder().encode(manifest)
        #expect(throws: PluginManifestError.self) { try PluginManifestConverter.decodePackage(from: data) }

        var nonExecSetup = PluginManifestConverter.manifest(from: try builtIn("gcloud-workflow"))
        let setupIndex = try #require(nonExecSetup.components.firstIndex { $0.kind == .setup })
        nonExecSetup.components[setupIndex].setup.check = PluginSetupStep(kind: .url, url: URL(string: "https://example.com"))
        #expect(throws: PluginManifestError.self) {
            try PluginManifestConverter.decodePackage(from: JSONEncoder().encode(nonExecSetup))
        }
    }

    @Test("A component ID the package would re-derive is refused, not silently replaced")
    func undeclarableComponentIDsAreRefused() throws {
        // Unmodified conversions keep passing: their IDs are the derived ones.
        for file in try builtInFiles() {
            let original = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
            let manifest = PluginManifestConverter.manifest(from: original)
            #expect(throws: Never.self, "\(file.lastPathComponent)") { try PluginManifestConverter.checkedPackage(from: manifest) }
        }
        let jira = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        let workspace = PluginManifestConverter.manifest(from: try builtIn("google-workspace"))
        for (manifest, kind) in [(jira, PluginComponent.Kind.skill), (jira, .connector), (workspace, .mcp)] {
            var renamed = manifest
            let index = try #require(renamed.components.firstIndex { $0.kind == kind })
            renamed.components[index].id = "stable-\(kind.rawValue)-id"
            #expect(throws: PluginManifestError.unrepresentableComponentID(
                component: renamed.components[index].name, id: "stable-\(kind.rawValue)-id"
            )) { try PluginManifestConverter.decodePackage(from: JSONEncoder().encode(renamed)) }
        }
        // A tool or template declaring its own ID is refused the same way.
        var package = try builtIn("gcloud-workflow")
        package.templates = [PluginTemplate(
            name: "Weekly Report", icon: "doc", description: "", mainGoal: "Report", beforeGoal: "", afterGoal: "",
            mainBudget: 1, beforeBudget: 0, afterBudget: 0, variablesJSON: "[]", passContextToMain: false, passContextToAfter: false
        )]
        let derived = PluginManifestConverter.manifest(from: package)
        #expect(throws: Never.self) { try PluginManifestConverter.checkedPackage(from: derived) }
        for kind in [PluginComponent.Kind.tool, .template] {
            var declared = derived
            let index = try #require(declared.components.firstIndex { $0.kind == kind })
            declared.components[index].id = "stable-\(kind.rawValue)-id"
            #expect(throws: PluginManifestError.self, "\(kind)") { try PluginManifestConverter.checkedPackage(from: declared) }
        }
    }

    @Test("A hint's first backticked command is the repair command")
    func firstCommandExtraction() {
        #expect(PluginManifestConverter.firstCommand("Run `gh auth login`.") == "gh auth login")
        #expect(PluginManifestConverter.firstCommand("Start Docker Desktop.") == nil)
    }

    // MARK: - Fixtures

    private func builtInFiles() throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func builtIn(_ id: String) throws -> PluginPackage {
        let file = try #require(try builtInFiles().first { $0.deletingPathExtension().lastPathComponent == id })
        return try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
    }

    private func canonical(_ package: PluginPackage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(package), as: UTF8.self)
    }
}
