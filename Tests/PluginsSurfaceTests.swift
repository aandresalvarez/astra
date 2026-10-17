import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The Plugins 2.0 surface: three groups with status on the heading, search
/// over what a plugin contains, and a one-step Add that approves before it
/// enables.
@Suite("Plugins surface")
@MainActor
struct PluginsSurfaceTests {
    @Test("Added plugins with work left need action, the rest are ready, the others are available to add")
    func groupsByWhatIsLeft() {
        let state = PluginsSurfacePresentation.makeState([
            input(package("zeta", name: "Zeta"), isEnabled: false),
            input(package("jira", name: "Jira"), isEnabled: true, pendingSteps: 1),
            input(package("github", name: "GitHub"), isEnabled: true),
            input(package("hidden", name: "Hidden"), isEnabled: false, isVisible: false),
            input(package("alpha", name: "Alpha"), isEnabled: false)
        ], query: "")

        #expect(state.actionNeeded.map(\.id) == ["jira"])
        #expect(state.actionNeeded.first?.subtitle == "1 step pending · 1 skill")
        #expect(state.actionNeeded.first?.verb == nil)
        #expect(state.ready.map(\.id) == ["github"])
        #expect(state.available.map(\.id) == ["alpha", "zeta"])
        #expect(state.available.allSatisfy { $0.verb == .add })
    }

    @Test("Turning off and removing say exactly what they delete and what stays")
    func destructiveActionsConfirm() {
        let off = PluginsSurfaceConfirmation.turnOff(packageID: "jira").copy(name: "Jira", hasAccounts: true)
        #expect(off.verb == "Turn off")
        // Turning off deletes nothing.
        #expect(off.message.contains("in this workspace") && off.message.contains("Nothing is deleted"))
        #expect(!off.message.contains("are deleted"))
        let remove = PluginsSurfaceConfirmation.remove(packageID: "jira").copy(name: "Jira", hasAccounts: true)
        #expect(remove.verb == "Remove")
        #expect(remove.message.contains("every workspace"))
        // Remove keeps accounts and their keys; only Delete account clears them.
        #expect(remove.message.contains("saved keys stay"))
        #expect(!PluginsSurfaceConfirmation.remove(packageID: "x").copy(name: "X", hasAccounts: false).message.contains("keys"))
    }

    @Test("Expanded plugin rows are remembered per workspace")
    func expansionIsRemembered() throws {
        let defaults = InMemoryDefaults()
        let first = UUID()
        let second = UUID()
        PluginsSurfacePreferences.setExpandedPluginIDs(["jira", "github"], workspaceID: first, in: defaults)
        #expect(PluginsSurfacePreferences.expandedPluginIDs(workspaceID: first, in: defaults) == ["jira", "github"])
        #expect(PluginsSurfacePreferences.expandedPluginIDs(workspaceID: second, in: defaults).isEmpty)
        PluginsSurfacePreferences.setExpandedPluginIDs([], workspaceID: first, in: defaults)
        #expect(PluginsSurfacePreferences.expandedPluginIDs(workspaceID: first, in: defaults).isEmpty)
    }

    @Test("A row projected from a standalone skill is not a library plugin, so it offers no Remove")
    @MainActor
    func projectedSkillRowsAreNotRemovable() {
        var synthetic = package("skill.1234", name: "My skill")
        synthetic.sourceMetadata = CapabilitySourceMetadata(id: "workspace", displayName: "Workspace", kind: "workspace", trustLevel: "local")
        #expect(!PluginsSurfaceView.isRemovable(synthetic))
        #expect(PluginsSurfaceView.isRemovable(package("imported.plugin", name: "Imported")))
    }

    @Test("Search reaches inside a plugin: bigquery finds Google Cloud through its bq tool")
    func searchReachesComponents() throws {
        let gcloud = try builtIn("gcloud-workflow")
        #expect(PluginsSurfacePresentation.matches(gcloud, query: "bigquery"))
        #expect(PluginsSurfacePresentation.matches(gcloud, query: "gsutil"))
        #expect(!PluginsSurfacePresentation.matches(gcloud, query: "redcap"))
        let workspace = try builtIn("google-workspace")
        #expect(PluginsSurfacePresentation.matches(workspace, query: "gmail"))
    }

    @Test("Adding a draft plugin writes the person's approval, then enables it here")
    func addApprovesThenEnables() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Add", primaryPath: "/tmp/plugins-add")
        context.insert(workspace)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-add-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root.appendingPathComponent("library"))
        let approvals = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals"))
        let draft = package("draft-plugin", name: "Draft Plugin", governance: .localDraft())
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [])
        #expect(!CapabilityCatalogPolicy.decision(for: draft, context: policy).canEnable)

        try CapabilityCatalogActionService(library: library).add(
            draft, workspace: workspace, modelContext: context,
            policyContext: policy, approvalStore: approvals, traceID: "trace-add"
        )

        let record = try #require(approvals.records().first { $0.packageID == draft.id })
        #expect(record.status == .approved)
        #expect(record.approvedBy == "user")
        #expect(WorkspaceCapabilityActivation.state(of: workspace).capabilityIDs == [draft.id])
        withExtendedLifetime(container) {}
    }

    @Test("The preview is on by default in development builds only, and remembers a choice")
    func previewFlagDefaultsByChannel() {
        let defaults = InMemoryDefaults()
        #expect(PluginsSurfacePreferences.isEnabled(in: defaults, channel: .development))
        #expect(!PluginsSurfacePreferences.isEnabled(in: defaults, channel: .production))
        PluginsSurfacePreferences.setEnabled(true, in: defaults)
        #expect(PluginsSurfacePreferences.isEnabled(in: defaults, channel: .production))
    }

    // MARK: - Fixtures

    private func input(
        _ package: PluginPackage,
        isEnabled: Bool,
        pendingSteps: Int = 0,
        isVisible: Bool = true
    ) -> PluginsSurfacePresentation.Input {
        PluginsSurfacePresentation.Input(
            package: package, isEnabled: isEnabled, pendingSteps: pendingSteps,
            isVisible: isVisible, isRemovable: true
        )
    }

    private func package(_ id: String, name: String, governance: CapabilityGovernance = .builtInApproved()) -> PluginPackage {
        PluginPackage(
            id: id, name: name, icon: "puzzlepiece.extension", description: "\(name) plugin",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "\(name) Agent", icon: "sparkles", description: "", allowedTools: ["Read"],
                    disallowedTools: [], customTools: [], behaviorInstructions: "Help.",
                    environmentKeys: [], environmentValues: []
                )
            ],
            connectors: [], localTools: [], templates: [], governance: governance
        )
    }

    private func builtIn(_ id: String) throws -> PluginPackage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities/\(id).json")
        return try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: url))
    }

    @Test("A manifest of another version, or one restricting a runtime ASTRA can't enforce, is refused")
    func manifestsFailClosed() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        var future = PluginManifestConverter.manifest(from: jira)
        future.manifestVersion = 2
        #expect(throws: PluginManifestError.unsupportedVersion(2)) { try PluginManifestConverter.checkedPackage(from: future) }
        var restricted = PluginManifestConverter.manifest(from: jira)
        restricted.worksOn["cursor_cli"] = .unsupported
        #expect(throws: PluginManifestError.unenforcedRuntimeRestriction(runtime: "cursor_cli")) {
            try PluginManifestConverter.checkedPackage(from: restricted)
        }
        #expect((try? PluginManifestConverter.checkedPackage(from: PluginManifestConverter.manifest(from: jira))) != nil)
    }

    @Test("A repair or install link opens only an https page")
    func repairURLsAreWebPages() throws {
        #expect(RepairAction.isSafeRepairURL(try #require(URL(string: "https://cloud.google.com/sdk"))))
        for unsafe in ["file:///etc/passwd", "smb://share/x", "x-custom://open", "http://example.com"] {
            #expect(!RepairAction.isSafeRepairURL(try #require(URL(string: unsafe))), "\(unsafe)")
        }
        var package = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        package.prerequisites[0].installURL = URL(string: "file:///Applications/Calculator.app")
        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Unsafe install link" })
    }

    @Test("Importing a Plugins 2.0 manifest file decodes it as a package")
    func manifestFilesImport() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let data = try JSONEncoder().encode(PluginManifestConverter.manifest(from: jira))
        let report = CapabilityPackageValidator.validate(data: data, installedPackages: [], checkPrerequisites: false)
        #expect(report.package?.id == "jira-workflow")
        #expect(report.package?.connectors.count == jira.connectors.count)
    }
}
