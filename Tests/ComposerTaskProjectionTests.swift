import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The new-task composer evaluates the task it *would* submit on every typing
/// pause, and scopes skills for it again on Run. Both used to relate an
/// unmanaged `AgentTask` to the managed selected skills, which made SwiftData
/// adopt it; the next save persisted it as a `draft` row. The runtime preview
/// anchors its id to the workspace (or the live draft), so the store ended up
/// with draft rows whose ZID was the workspace's UUID — or a real draft's.
@Suite("Composer task projection")
@MainActor
struct ComposerTaskProjectionTests {
    private struct Fixture {
        let container: ModelContainer
        let workspace: Workspace
        let skill: Skill
        let root: URL

        @MainActor var context: ModelContext { container.mainContext }
    }

    /// The container is returned so its models outlive the helper.
    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-composer-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "test", primaryPath: root.path)
        context.insert(workspace)
        let skill = Skill(
            name: "Zebrafish",
            skillDescription: "Summarize zebrafish assay notes",
            behaviorInstructions: "Summarize zebrafish assay notes carefully."
        )
        context.insert(skill)
        let connector = Connector(name: "Zebrafish Registry", serviceType: "custom")
        context.insert(connector)
        connector.skill = skill
        try context.save()
        return Fixture(container: container, workspace: workspace, skill: skill, root: root)
    }

    private func previewRequest(
        _ fixture: Fixture,
        draftTask: AgentTask?
    ) -> RuntimeEligibilityPreviewRequest {
        .newTask(
            draftTask: draftTask,
            workspace: fixture.workspace,
            selectedSkills: [fixture.skill],
            attachedFiles: [],
            acceptedTurn: "Create notes-b.txt and summarize the zebrafish assay notes in it",
            requestedRuntime: .claudeCode,
            runtimeExplicitlySelected: false,
            selectedPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue,
            skipPermissions: true,
            defaultModel: "test-model",
            defaultBudget: 1_000,
            providerSettings: .headlessScenario,
            readinessStates: [.claudeCode: .ready]
        )
    }

    private func storedTaskIDs(_ context: ModelContext) throws -> [UUID] {
        try context.fetch(FetchDescriptor<AgentTask>()).map(\.id)
    }

    @Test("The runtime preview of a new task never persists a task of its own")
    func runtimePreviewLeavesNoPhantomDraft() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let request = previewRequest(fixture, draftTask: nil)
        // The typing path scores the selected runtime, then everything.
        _ = try #require(await request.evaluate(candidateRuntimes: [.claudeCode]))
        _ = try #require(await request.evaluate())
        try fixture.context.save()

        #expect(try storedTaskIDs(fixture.context).isEmpty)
        #expect(try fixture.context.fetchCount(FetchDescriptor<TaskEvent>()) == 0)
        #expect(fixture.skill.tasks.isEmpty)
        #expect(fixture.workspace.tasks.isEmpty)
    }

    @Test("The runtime preview over a saved draft never duplicates the draft's id")
    func runtimePreviewNeverDuplicatesDraftID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draft = AgentTask(title: "Plan", goal: "Plan the notes", workspace: fixture.workspace)
        fixture.context.insert(draft)
        try fixture.context.save()

        let request = previewRequest(fixture, draftTask: draft)
        _ = try #require(await request.evaluate(candidateRuntimes: [.claudeCode]))
        _ = try #require(await request.evaluate())
        try fixture.context.save()

        #expect(try storedTaskIDs(fixture.context) == [draft.id])
        #expect(draft.events.isEmpty)
    }

    @Test("A selected skill keeps its connector in the detached preview")
    func detachedPreviewKeepsSkillConnectors() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let preview = ComposerTaskProjection.detachedTask(
            title: "Preview",
            goal: "Summarize the zebrafish assay notes",
            workspace: fixture.workspace,
            skills: [fixture.skill],
            inputs: []
        )

        #expect(preview.modelContext == nil)
        #expect(preview.workspace === fixture.workspace)
        let clone = try #require(preview.skills.first)
        #expect(clone !== fixture.skill)
        #expect(clone.modelContext == nil)
        #expect(clone.id == fixture.skill.id)
        #expect(clone.connectors.map(\.name) == ["Zebrafish Registry"])
        #expect(fixture.skill.tasks.isEmpty)
    }

    @Test("A selected skill's workspace-owned connector stays in the preview's inventory")
    func detachedPreviewKeepsWorkspaceOwnedConnectors() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owned = Connector(name: "Workspace Jira", serviceType: "jira")
        fixture.context.insert(owned)
        owned.skill = fixture.skill
        owned.workspace = fixture.workspace
        try fixture.context.save()

        let preview = ComposerTaskProjection.detachedTask(
            title: "Preview",
            goal: "Summarize the zebrafish assay notes",
            workspace: fixture.workspace,
            skills: [fixture.skill],
            inputs: []
        )

        #expect(preview.modelContext == nil)
        let clone = try #require(preview.skills.first?.connectors.first { $0.id == owned.id })
        #expect(clone.workspace?.id == fixture.workspace.id)
        #expect(clone.workspace !== fixture.workspace)
        #expect(TaskCapabilityResolver(task: preview).allConnectors.contains { $0.id == owned.id })
        try fixture.context.save()
        #expect(try storedTaskIDs(fixture.context).isEmpty)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Workspace>()) == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Connector>()) == 2)
    }

    @Test("Scoping skills on Run returns the managed skills and leaves no probe task behind")
    func skillScopeProbeLeavesNoPhantomDraft() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let scoped = ComposerTaskProjection.scopedSkills(
            [fixture.skill],
            forTaskText: "Summarize the zebrafish assay notes",
            inputs: ["/tmp/assay.csv"],
            workspace: fixture.workspace
        )
        try fixture.context.save()

        #expect(scoped.count == 1)
        #expect(scoped.first === fixture.skill)
        #expect(try storedTaskIDs(fixture.context).isEmpty)
        #expect(fixture.skill.tasks.isEmpty)
    }
}
