import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeFollowUpGoalFramingContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

/// PR 2: Tier 1 completion-aware framing in the follow-up prompt.
///
/// Verifies `FollowUpIntroSectionProvider` in `AgentPromptBuilder` reframes the static
/// `task.goal` block once `TaskContextStateManager.originalGoalDelivery(for:)` reports
/// `.delivered`, and leaves `.active` threads byte-for-byte on today's behavior
/// (regression guard for INVARIANT #1 / #3 / #5 in plan-goal-capsule.md).
@Suite("Follow-up goal framing")
@MainActor
struct FollowUpGoalFramingTests {
    @Test("delivered original goal is demoted to background framing")
    func deliveredGoalIsDemotedToBackgroundFraming() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Completed thread", goal: "Write the onboarding guide")
        task.status = .completed
        context.insert(task)
        try context.save()

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .delivered)

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)

        // The imperative "Goal: <goal>" phrasing must be gone.
        #expect(!prompt.contains("Goal: Write the onboarding guide"))
        // The artifact-first-action requirement must not re-trigger redelivery.
        #expect(!prompt.contains("Artifact first-action requirement:"))
        #expect(!prompt.contains("Your first provider-visible action should be to create or update a useful baseline deliverable"))
        // The goal text must still be present verbatim, framed as background-only context.
        #expect(prompt.contains("Write the onboarding guide"))
        #expect(prompt.contains("already delivered"))
        #expect(prompt.contains("background context only"))
        #expect(prompt.contains("do not re-address unless the user asks"))
        // A transparency note must explain the demotion (never silently re-anchor).
        #expect(prompt.contains("Transparency note:"))
    }

    @Test("active original goal keeps today's imperative framing")
    func activeGoalKeepsCurrentFraming() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide")
        task.status = .running
        context.insert(task)
        try context.save()

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)

        // Regression guard: unchanged imperative phrasing for still-active threads.
        #expect(prompt.contains("Goal: Write the onboarding guide"))
        #expect(!prompt.contains("already delivered"))
        #expect(!prompt.contains("Transparency note:"))
    }

    // PR 6: Tier 2 (utility-model) objective assessment consumed in follow-up framing.
    // The prompt builder only reads the persisted `objectiveAssessment` -- these tests
    // never invoke `ObjectiveAssessmentService`, they seed the capsule directly.

    @Test("superseded Tier 2 verdict demotes the original goal and surfaces a divergence note")
    func supersededVerdictDemotesOriginalGoalWithDivergenceNote() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "superseded")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Superseded", primaryPath: root)
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)
        try context.save()

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: folder))
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Rework the CSV exporter instead",
            assessedAtTurn: 4,
            inputHash: "hash-superseded"
        )
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)

        // Original goal text is never deleted -- only demoted to background framing.
        #expect(prompt.contains("Write the onboarding guide"))
        #expect(!prompt.contains("Goal: Write the onboarding guide"))
        #expect(prompt.contains("background context only"))
        #expect(prompt.contains("do not re-address unless the user asks"))
        // Divergence must be auditable and explicitly say "superseded" (INVARIANT #1).
        #expect(prompt.contains("Transparency note:"))
        #expect(prompt.contains("superseded"))
        // The live directive surfaced to the model is the Tier 2 current objective,
        // carried by the capsule's own Thread Intent / Objective assessment rendering
        // rather than a second, possibly-conflicting string invented by this section.
        #expect(prompt.contains("Rework the CSV exporter instead"))
        // Regression guard (adversarial finding): the capsule's own Thread Intent
        // "Current objective" line must be reconciled to the Tier 2 pivot, not
        // left on the stale Tier 1 text -- otherwise the prompt contains two
        // contradictory "Current objective" values in the same turn.
        #expect(!prompt.contains("- Current objective: Write the onboarding guide"))
        #expect(prompt.contains("- Current objective: Rework the CSV exporter instead"))
    }

    @Test("a newer explicit objective marker invalidates a stale superseded Tier 2 verdict")
    func explicitObjectiveMarkerInvalidatesStaleSupersededVerdict() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "explicit-marker-invalidates")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Explicit Marker Invalidates", primaryPath: root)
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)

        let first = TaskEvent(task: task, type: "user.message", payload: "Write the onboarding guide")
        first.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(first)

        // Turn 10 (per adversarial finding): the user explicitly overrides back
        // to the original goal after an earlier, now-stale Tier 2 drift episode.
        let explicitCorrection = TaskEvent(
            task: task,
            type: "user.message",
            payload: "no wait, go back -- your goal is to finish the onboarding guide"
        )
        explicitCorrection.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(explicitCorrection)
        try context.save()

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: folder))
        // Simulate the earlier turn-6 Tier 2 pivot that was never cleared.
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Rework the CSV exporter instead",
            assessedAtTurn: 4,
            inputHash: "hash-stale-superseded"
        )
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)

        // Tier 1's explicit marker wins: the stale Tier 2 pivot must not demote
        // the original goal or surface the earlier drift episode's objective.
        #expect(prompt.contains("Goal: Write the onboarding guide"))
        #expect(!prompt.contains("Rework the CSV exporter instead"))
        #expect(!prompt.contains("superseded by later work"))
        // The reconciled Thread Intent line must reflect the explicit correction,
        // not the stale Tier 2 text.
        #expect(prompt.contains("- Current objective: finish the onboarding guide"))
    }

    @Test("no objectiveAssessment (Tier 2 never ran) matches PR 2 behavior exactly")
    func missingAssessmentMatchesPriorBehavior() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext

        let activeTask = AgentTask(title: "Running thread", goal: "Write the onboarding guide")
        activeTask.status = .running
        context.insert(activeTask)

        let deliveredTask = AgentTask(title: "Completed thread", goal: "Write the onboarding guide")
        deliveredTask.status = .completed
        context.insert(deliveredTask)
        try context.save()

        #expect(TaskContextStateManager.originalGoalDelivery(for: activeTask) == .active)
        #expect(TaskContextStateManager.originalGoalDelivery(for: deliveredTask) == .delivered)

        let activePrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: activeTask)
        #expect(activePrompt.contains("Goal: Write the onboarding guide"))
        #expect(!activePrompt.contains("already delivered"))
        #expect(!activePrompt.contains("Transparency note:"))

        let deliveredPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: deliveredTask)
        #expect(!deliveredPrompt.contains("Goal: Write the onboarding guide"))
        #expect(deliveredPrompt.contains("Write the onboarding guide"))
        #expect(deliveredPrompt.contains("already delivered"))
        #expect(deliveredPrompt.contains("background context only"))
        #expect(deliveredPrompt.contains("do not re-address unless the user asks"))
        #expect(deliveredPrompt.contains("Transparency note:"))
    }

    private static func temporaryRoot(name: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-follow-up-goal-framing-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
