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

    @Test("A connector's setup asks for its credentials, and an MCP-only plugin is unsupported where MCP does not reach")
    func connectorSetupAndWorksOn() throws {
        let jira = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        let connector = try #require(jira.components.first { $0.kind == .connector })
        #expect(connector.setup.connect?.kind == .credentialForm)
        #expect(connector.setup.connect?.fields?.isEmpty == false)
        #expect(jira.worksOn["cursor_cli"] == .full)

        let workspace = PluginManifestConverter.manifest(from: try builtIn("google-workspace"))
        #expect(workspace.components.filter { $0.kind == .mcp }.count == 3)
        #expect(workspace.worksOn["claude_code"] == .full)
        // Nothing in it reaches a runtime without MCP delivery.
        #expect(workspace.worksOn["cursor_cli"] == .unsupported)
        #expect(workspace.worksOn["antigravity_cli"] == .unsupported)
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

    @Test("An empty setup component, or a requirement on another kind, is refused rather than dropped or split")
    func emptyOrMisplacedSetupPayloadIsRefused() throws {
        let base = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        #expect(throws: Never.self) { try PluginManifestConverter.checkedPackage(from: base) }

        var empty = base
        empty.components.append(PluginComponent(kind: .setup, id: "account", name: "Account"))
        #expect(throws: PluginManifestError.mismatchedPayload(component: "Account")) {
            try PluginManifestConverter.checkedPackage(from: empty)
        }

        let requirement = PluginSetupRequirement(id: "jira-account", kind: .oauthAccount, displayName: "Jira account")
        var withRequirement = base
        withRequirement.components.append(PluginComponent(
            kind: .setup, id: requirement.id, name: requirement.displayName, requirement: requirement
        ))
        #expect(throws: Never.self) { try PluginManifestConverter.checkedPackage(from: withRequirement) }

        var misplaced = base
        let skillIndex = try #require(misplaced.components.firstIndex { $0.kind == .skill })
        misplaced.components[skillIndex].requirement = requirement
        #expect(throws: PluginManifestError.mismatchedPayload(component: misplaced.components[skillIndex].name)) {
            try PluginManifestConverter.checkedPackage(from: misplaced)
        }
    }

    @Test("A declared component ID is kept as the identity where the package can carry it, and refused where it can't")
    func undeclarableComponentIDsAreRefused() throws {
        // Unmodified conversions keep passing: their IDs are the derived ones.
        for file in try builtInFiles() {
            let original = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
            let manifest = PluginManifestConverter.manifest(from: original)
            #expect(throws: Never.self, "\(file.lastPathComponent)") { try PluginManifestConverter.checkedPackage(from: manifest) }
        }
        // Skills, connectors and tools carry a declared ID on their payload.
        let jira = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        for kind in [PluginComponent.Kind.skill, .connector] {
            var declared = jira
            let index = try #require(declared.components.firstIndex { $0.kind == kind })
            declared.components[index].id = "stable-\(kind.rawValue)-id"
            let package = try PluginManifestConverter.decodePackage(from: JSONEncoder().encode(declared))
            let id = kind == .skill ? package.skills.first?.id : package.connectors.first?.id
            #expect(id == "stable-\(kind.rawValue)-id")
        }
        // An MCP server's ID is its own; a template has none to carry.
        let workspace = PluginManifestConverter.manifest(from: try builtIn("google-workspace"))
        var mcp = workspace
        let mcpIndex = try #require(mcp.components.firstIndex { $0.kind == .mcp })
        mcp.components[mcpIndex].id = "stable-mcp-id"
        #expect(throws: PluginManifestError.unrepresentableComponentID(
            component: mcp.components[mcpIndex].name, id: "stable-mcp-id"
        )) { try PluginManifestConverter.decodePackage(from: JSONEncoder().encode(mcp)) }
        var package = try builtIn("gcloud-workflow")
        package.templates = [PluginTemplate(
            name: "Weekly Report", icon: "doc", description: "", mainGoal: "Report", beforeGoal: "", afterGoal: "",
            mainBudget: 1, beforeBudget: 0, afterBudget: 0, variablesJSON: "[]", passContextToMain: false, passContextToAfter: false
        )]
        let derived = PluginManifestConverter.manifest(from: package)
        #expect(throws: Never.self) { try PluginManifestConverter.checkedPackage(from: derived) }
        var tool = derived
        let toolIndex = try #require(tool.components.firstIndex { $0.kind == .tool })
        tool.components[toolIndex].id = "stable-tool-id"
        #expect(try PluginManifestConverter.checkedPackage(from: tool).localTools.first?.id == "stable-tool-id")
        var template = derived
        let templateIndex = try #require(template.components.firstIndex { $0.kind == .template })
        template.components[templateIndex].id = "stable-template-id"
        #expect(throws: PluginManifestError.self) { try PluginManifestConverter.checkedPackage(from: template) }
    }

    @Test("Two connectors sharing a name keep their own setup: each is checked against its own ID")
    func sameNamedConnectorsKeepTheirOwnSetup() throws {
        var package = try builtIn("jira-workflow")
        let index = try #require(package.connectors.firstIndex { !$0.credentialHints.isEmpty })
        var second = package.connectors[index]
        package.connectors[index].id = "jira-cloud"
        second.id = "jira-server"
        second.credentialHints = [.init(key: "JIRA_SERVER_PAT", hint: "Personal access token")]
        package.connectors.insert(second, at: index + 1)
        let manifest = PluginManifestConverter.manifest(from: package)
        let forms = manifest.components.filter { $0.kind == .connector && $0.name == second.name }.map(\.setup.connect?.fields)
        #expect(forms.count == 2 && forms[0] != forms[1])

        let checked = try PluginManifestConverter.checkedPackage(from: manifest)
        #expect(checked.connectors[index].id == "jira-cloud")
        #expect(checked.connectors[index + 1].credentialHints.map(\.key) == ["JIRA_SERVER_PAT"])
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
