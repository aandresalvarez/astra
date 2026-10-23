import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The Plugins 2.0 manifest projects into today's packages losslessly, so the
/// library, installer and runtime keep working unchanged underneath it.
@Suite("Plugin manifest")
struct PluginManifestTests {
    @Test("A version-marked incomplete manifest cannot fall back to legacy decoding", arguments: [1, 999])
    func incompleteVersionMarkedManifestFailsClosed(version: Int) throws {
        var hybrid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(builtIn("gcloud-workflow"))) as? [String: Any])
        hybrid["manifestVersion"] = version
        hybrid["worksOn"] = ["claude_code": "unsupported"]
        let data = try JSONSerialization.data(withJSONObject: hybrid)
        #expect(PluginManifestConverter.isManifest(data))
        #expect(throws: (any Error).self) { try PluginManifestConverter.decodePackage(from: data) }
    }

    @Test("An MCP process-start check that the package cannot carry is rejected")
    func processStartCheckIsNotSilentlyAccepted() throws {
        var package = try builtIn("google-workspace")
        package.mcpServers = [PluginMCPServer(id: "fixture", displayName: "Fixture MCP", transport: .stdio, command: "astra-test-mcp-missing")]
        package.prerequisites = []
        var manifest = PluginManifestConverter.manifest(from: package)
        let index = try #require(manifest.components.firstIndex { $0.kind == .mcp })
        manifest.components[index].setup.check = PluginSetupStep(kind: .processStarts)
        #expect(throws: PluginManifestError.unrepresentableSetup(component: "Fixture MCP")) {
            try PluginManifestConverter.checkedPackage(from: manifest)
        }
    }

    @Test("Projecting an MCP package does not invent a check with no executable prerequisite")
    func packageProjectionDoesNotInventProcessChecks() throws {
        var package = try builtIn("google-workspace")
        package.prerequisites = []
        let manifest = PluginManifestConverter.manifest(from: package)
        #expect(manifest.components.filter { $0.kind == .mcp }.allSatisfy { $0.setup.isEmpty })
        #expect(try canonical(PluginManifestConverter.checkedPackage(from: manifest)) == canonical(package))
    }

    @Test("An explicit read-only MCP executable check remains actionable when its command is missing")
    func representableMCPAvailabilityCheckIsPreserved() async throws {
        var package = try builtIn("google-workspace")
        let command = "astra-test-mcp-missing"
        package.mcpServers = [PluginMCPServer(id: "fixture", displayName: "Fixture MCP", transport: .stdio, command: command)]
        package.prerequisites = [CLIPrerequisite(binary: command, livenessArgs: [], displayName: "Fixture executable", purpose: "Launches the MCP server.", installHint: "Install the server.")]
        let manifest = PluginManifestConverter.manifest(from: package)
        let restored = try PluginManifestConverter.checkedPackage(from: manifest)
        let prerequisite = try #require(restored.prerequisites.first)
        let runner = StubBinaryRunner()
        let status = await EnvironmentHealthChecker(runner: runner, fallbackDirectories: []).check(binary: prerequisite.binary, livenessArgs: prerequisite.livenessArgs)
        #expect(status == .missingBinary)
        #expect(PluginsSurfacePresentation.pendingSetupChecks(for: restored, statuses: [prerequisite.id: status]) == 1)
        #expect(await runner.recordedCalls().map(\.args) == [["which", command]])
    }

    @Test("Built-in manifests preserve every payload field while canonicalizing stable tool IDs")
    func builtInsRoundTripLosslessly() throws {
        let files = try builtInFiles()
        #expect(files.count >= 10)
        for file in files {
            let original = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
            let manifest = PluginManifestConverter.manifest(from: original)
            let restored = PluginManifestConverter.package(from: manifest)
            var payload = restored
            let toolComponents = manifest.components.filter { $0.kind == .tool }
            #expect(restored.localTools.count == original.localTools.count)
            for index in original.localTools.indices {
                #expect(restored.localTools[index].id == toolComponents[index].id)
                // Identity is checked separately; every other field must survive.
                payload.localTools[index].id = original.localTools[index].id
                payload.localTools[index].replaces = original.localTools[index].replaces
            }
            #expect(try canonical(payload) == canonical(original), "\(file.lastPathComponent) payload changed")
            let again = try PluginManifestConverter.checkedPackage(from: PluginManifestConverter.manifest(from: restored))
            #expect(try canonical(again) == canonical(restored))
        }
    }

    @Test("A manifest survives JSON and decodes back into the same package")
    func manifestJSONRoundTrips() throws {
        for file in try builtInFiles() {
            let original = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
            let manifest = PluginManifestConverter.manifest(from: original)
            let data = try JSONEncoder().encode(manifest)
            #expect(PluginManifestConverter.isManifest(data))
            let expected = try PluginManifestConverter.checkedPackage(from: manifest)
            #expect(try canonical(PluginManifestConverter.decodePackage(from: data)) == canonical(expected))
            // Direct legacy package decoding retains its original identities.
            #expect(try canonical(PluginManifestConverter.decodePackage(from: JSONEncoder().encode(original))) == canonical(original))
        }
        let packageData = try Data(contentsOf: try builtInFiles()[0])
        #expect(!PluginManifestConverter.isManifest(packageData))
    }

    @Test("A document with components but no manifestVersion is a manifest, and is refused")
    func componentsWithoutVersionAreRefused() throws {
        let original = try builtIn("gcloud-workflow")
        // A legacy package with a manifest's components but no version.
        var hybrid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let manifest = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(PluginManifestConverter.manifest(from: original))) as? [String: Any]
        )
        hybrid["components"] = manifest["components"]
        hybrid["worksOn"] = ["claude_code": "unsupported"]
        let data = try JSONSerialization.data(withJSONObject: hybrid)
        #expect(PluginManifestConverter.isManifest(data))
        do {
            let decoded = try PluginManifestConverter.decodePackage(from: data)
            Issue.record("imported as a package without its components: \(decoded.id)")
        } catch DecodingError.keyNotFound(let key, _) {
            #expect(key.stringValue == "manifestVersion")
        }
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

    @Test("Same-named components with distinct IDs claim no shared name-derived predecessor")
    func sameNamedComponentsClaimNoSharedPredecessor() throws {
        var package = try builtIn("jira-workflow")
        let index = try #require(package.connectors.firstIndex { !$0.credentialHints.isEmpty })
        var second = package.connectors[index]
        package.connectors[index].id = "jira-cloud"
        second.id = "jira-server"
        package.connectors.insert(second, at: index + 1)
        var lone = package.connectors[index]
        lone.name = "Jira Lone"
        lone.id = "jira-solo"
        package.connectors.append(lone)

        let checked = try PluginManifestConverter.checkedPackage(from: PluginManifestConverter.manifest(from: package))
        #expect(PluginUpdateService.replacesProblems(in: checked).isEmpty)
        #expect(checked.connectors[index].replaces == nil && checked.connectors[index + 1].replaces == nil)
        // A name only one component derives is still its predecessor.
        #expect(checked.connectors.last?.replaces?.count == 1)
    }

    @Test("A component name or summary its payload doesn't share is refused, not replaced by the payload's")
    func unrepresentableComponentLabelsAreRefused() throws {
        let jira = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        let workspace = PluginManifestConverter.manifest(from: try builtIn("google-workspace"))
        for (manifest, kind) in [(jira, PluginComponent.Kind.skill), (jira, .connector), (workspace, .mcp)] {
            let index = try #require(manifest.components.firstIndex { $0.kind == kind })
            var renamed = manifest
            renamed.components[index].name += " (team)"
            #expect(throws: PluginManifestError.unrepresentableComponentLabel(component: renamed.components[index].name), "\(kind)") {
                try PluginManifestConverter.checkedPackage(from: renamed)
            }
            var described = manifest
            described.components[index].summary = "A summary only the manifest has"
            #expect(throws: PluginManifestError.unrepresentableComponentLabel(component: described.components[index].name), "\(kind)") {
                try PluginManifestConverter.checkedPackage(from: described)
            }
        }
        // An account's label is its requirement's.
        let requirement = PluginSetupRequirement(id: "jira-account", kind: .oauthAccount, displayName: "Jira account")
        var account = jira
        account.components.append(PluginComponent(kind: .setup, id: requirement.id, name: "Atlassian login", requirement: requirement))
        #expect(throws: PluginManifestError.unrepresentableComponentLabel(component: "Atlassian login")) {
            try PluginManifestConverter.checkedPackage(from: account)
        }
    }

    @Test("A setup component ID the package would re-derive is refused, not silently replaced")
    func undeclarableSetupIDsAreRefused() throws {
        // A CLI check comes back with its name's slug.
        var cli = PluginManifestConverter.manifest(from: try builtIn("gcloud-workflow"))
        let cliIndex = try #require(cli.components.firstIndex { $0.kind == .setup && $0.requirement == nil })
        cli.components[cliIndex].id = "stable-cli-id"
        #expect(throws: PluginManifestError.unrepresentableComponentID(
            component: cli.components[cliIndex].name, id: "stable-cli-id"
        )) { try PluginManifestConverter.checkedPackage(from: cli) }

        // An account comes back with its requirement's ID, not the outer one.
        let requirement = PluginSetupRequirement(id: "jira-account", kind: .oauthAccount, displayName: "Jira account")
        var account = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        account.components.append(PluginComponent(
            kind: .setup, id: "outer-account-id", name: requirement.displayName, requirement: requirement
        ))
        #expect(throws: PluginManifestError.unrepresentableComponentID(
            component: "Jira account", id: "outer-account-id"
        )) { try PluginManifestConverter.checkedPackage(from: account) }
    }

    @Test("Two setup components sharing a name but checking different CLIs both round-trip")
    func sameNamedSetupComponentsRoundTripByPosition() throws {
        var manifest = PluginManifestConverter.manifest(from: try builtIn("gcloud-workflow"))
        var twin = try #require(manifest.components.first { $0.kind == .setup && $0.name == "Google Cloud login" })
        twin.setup.check?.arguments = ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"]
        manifest.components.append(twin)
        let package = try PluginManifestConverter.checkedPackage(from: manifest)
        let logins = package.prerequisites.filter { $0.displayName == "Google Cloud login" }
        #expect(logins.map(\.livenessArgs).last == twin.setup.check?.arguments)
        #expect(logins.count == 2)
        // A dropped step on the twin is still refused, named by its component.
        manifest.components[manifest.components.count - 1].setup.verify = PluginSetupStep(kind: .exec, binary: "gcloud")
        #expect(throws: PluginManifestError.unrepresentableSetup(component: "Google Cloud login")) {
            try PluginManifestConverter.checkedPackage(from: manifest)
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
