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

    @Test("A source plugin says where it comes from and what it leaves out; one that cannot be added says why")
    func sourcePluginRows() {
        var fromSource = input(package("notes", name: "Team Notes"), isEnabled: false)
        fromSource.sourceName = "org/plugins"
        fromSource.unsupported = ["1 agent", "hooks"]
        var blocked = input(package("jira-workflow", name: "Jira copy"), isEnabled: false)
        blocked.sourceName = "org/plugins"
        blocked.problem = "Uses the ID of a built-in plugin, so it cannot replace it."
        let state = PluginsSurfacePresentation.makeState([fromSource, blocked], query: "")
        let notes = state.available.first { $0.id == "notes" }
        #expect(notes?.subtitle == "1 skill · from org/plugins · without 1 agent, hooks")
        #expect(notes?.verb == .add)
        let copy = state.available.first { $0.id == "jira-workflow" }
        #expect(copy?.verb == nil)
        #expect(copy?.subtitle.contains("built-in") == true)
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
        #expect(workspace.capabilityActivation.capabilityIDs == [draft.id])
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
            isVisible: isVisible, isRemovable: true,
            recordedVersion: isEnabled ? package.version : nil
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
        return try PluginManifestConverter.decodePackage(from: Data(contentsOf: url))
    }
}
