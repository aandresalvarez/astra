import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The Plugins 2.0 manifest projects into today's packages losslessly, so the
/// library, installer and runtime keep working unchanged underneath it.
@Suite("Plugin manifest")
struct PluginManifestTests {
    @Test("Every built-in ships as a manifest that survives manifest → package → manifest unchanged")
    func builtInsRoundTripLosslessly() throws {
        let files = try builtInFiles()
        #expect(files.count >= 10)
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(PluginManifestConverter.isManifest(data), "\(file.lastPathComponent) is not a manifest")
            let shipped = try JSONDecoder().decode(PluginManifest.self, from: data)
            let package = PluginManifestConverter.package(from: shipped)
            let again = PluginManifestConverter.manifest(from: package)
            #expect(again == shipped, "\(file.lastPathComponent) changed in the round trip")
            #expect(try canonical(PluginManifestConverter.package(from: again)) == canonical(package))
        }
    }

    @Test("Every built-in file loads from the bundle; none is dropped for failing to decode")
    func everyBuiltInFileLoads() throws {
        let shipped = Set(try builtInFiles().map { $0.deletingPathExtension().lastPathComponent })
        #expect(Set(ApprovedCapabilityBundle.packages().map(\.id)) == shipped)
    }

    @Test("A manifest survives JSON and decodes back into the same package")
    func manifestJSONRoundTrips() throws {
        for file in try builtInFiles() {
            let original = try PluginManifestConverter.decodePackage(from: Data(contentsOf: file))
            let data = try JSONEncoder().encode(PluginManifestConverter.manifest(from: original))
            #expect(PluginManifestConverter.isManifest(data))
            #expect(try canonical(PluginManifestConverter.decodePackage(from: data)) == canonical(original))
        }
        let packageData = try JSONEncoder().encode(try builtIn("jira-workflow"))
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
        #expect(workspace.worksOn["copilot_cli"] == .fullWithRecentCLI)
        #expect(workspace.worksOn["cursor_cli"] == .shellOnly)
        #expect(workspace.worksOn["antigravity_cli"] == .shellOnly)
    }

    @Test("worksOn names every registered runtime and agrees with the MCP delivery matrix")
    func worksOnMatchesTheRuntimeMatrix() {
        let declared = PluginManifestConverter.mcpRuntimes
            .union(PluginManifestConverter.conditionalMCPRuntimes)
            .union(PluginManifestConverter.shellOnlyRuntimes)
        #expect(declared == Set(AgentRuntimeAdapterRegistry.descriptors.map(\.id.rawValue)))
        for profile in MCPRuntimeSupportMatrix.defaultProfiles() {
            let id = profile.runtimeID.rawValue
            if PluginManifestConverter.mcpRuntimes.contains(id) {
                #expect(profile.supportsDelivery, "\(id) is declared full but gets no MCP")
            } else if PluginManifestConverter.shellOnlyRuntimes.contains(id) {
                #expect(!profile.supportsDelivery, "\(id) is declared shell-only but gets MCP")
            }
        }
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

    @Test("Importing a manifest file reads it through the ordinary capability reader")
    func importReaderAcceptsAManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try builtIn("jira-workflow")
        try JSONEncoder().encode(PluginManifestConverter.manifest(from: original))
            .write(to: directory.appendingPathComponent(CapabilityPackageSourceReader.manifestFileName))

        let source = try CapabilityPackageSourceReader.read(at: directory)
        #expect(source.package.id == original.id)
        #expect(try canonical(source.package) == canonical(original))
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
        return try PluginManifestConverter.decodePackage(from: Data(contentsOf: file))
    }

    private func canonical(_ package: PluginPackage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(package), as: UTF8.self)
    }
}
