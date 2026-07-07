import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
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
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(true, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

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
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(true, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

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

    @Test("a live correction in the current follow-up message invalidates a stale pivot on this same turn")
    func liveFollowUpMessageInvalidatesStalePivotOnSameTurn() throws {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(true, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "live-followup-invalidates")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Live Follow-up Invalidates", primaryPath: root)
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: folder))
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Rework the CSV exporter instead",
            assessedAtTurn: 4,
            inputHash: "hash-stale-superseded"
        )
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)

        // The correction arrives as THIS turn's raw message, never persisted
        // as a `user.message` event beforehand -- `continueSession` builds
        // the prompt before recording that event, so a check based only on
        // `task.events` would still apply the stale pivot to this exact turn
        // (adversarial finding).
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "no wait, go back -- your goal is to Write the onboarding guide",
            task: task
        )

        #expect(prompt.contains("Goal: Write the onboarding guide"))
        #expect(!prompt.contains("Rework the CSV exporter instead"))
        #expect(!prompt.contains("superseded by later work"))
    }

    @Test("an explicit return to the original goal invalidates a stale superseded Tier 2 verdict")
    func explicitReturnToOriginalGoalInvalidatesStaleSupersededVerdict() throws {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(true, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "explicit-return-to-original")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Explicit Return To Original", primaryPath: root)
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)

        let first = TaskEvent(task: task, type: "user.message", payload: "Write the onboarding guide")
        first.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(first)

        // Unlike `explicitMarkerInvalidatesStaleSupersededVerdict` above, this
        // correction resolves back to the EXACT original goal text, so
        // `supersedesOriginalGoal` reads false -- but it's still a fresh,
        // explicit correction and must still invalidate the stale pivot
        // (adversarial finding).
        let explicitReturn = TaskEvent(
            task: task,
            type: "user.message",
            payload: "no wait, go back -- your goal is to Write the onboarding guide"
        )
        explicitReturn.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(explicitReturn)
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

        // The just-reaffirmed original goal must be active, not demoted, and
        // the earlier drift episode's objective must not resurface anywhere.
        #expect(prompt.contains("Goal: Write the onboarding guide"))
        #expect(!prompt.contains("Rework the CSV exporter instead"))
        #expect(!prompt.contains("superseded by later work"))
        #expect(prompt.contains("- Current objective: Write the onboarding guide"))
    }

    @Test("artifact delivery contract is suppressed once the original deliverable is demoted")
    func artifactDeliveryContractSuppressedOnceDemoted() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        // `standaloneArtifactDirective` only fires once
        // `TaskWorkspaceAccess(task:).taskFolder` resolves to a real folder, so
        // both tasks need a workspace (unlike the plain no-workspace tasks
        // elsewhere in this file, which only exercise `FollowUpIntroSectionProvider`).
        let activeRoot = try Self.temporaryRoot(name: "artifact-contract-active")
        defer { try? FileManager.default.removeItem(atPath: activeRoot) }
        let deliveredRoot = try Self.temporaryRoot(name: "artifact-contract-delivered")
        defer { try? FileManager.default.removeItem(atPath: deliveredRoot) }

        // "Write" (action word) + "demo app" (artifact keyword) makes
        // `TaskDeliverableExpectation.requiresDeliverableArtifact` true.
        let activeWorkspace = Workspace(name: "Artifact Contract Active", primaryPath: activeRoot)
        let activeTask = AgentTask(title: "Running thread", goal: "Write a demo app for onboarding", workspace: activeWorkspace)
        activeTask.status = .running
        context.insert(activeWorkspace)
        context.insert(activeTask)
        _ = try TaskWorkspaceAccess(task: activeTask).ensureTaskFolder()

        let deliveredWorkspace = Workspace(name: "Artifact Contract Delivered", primaryPath: deliveredRoot)
        let deliveredTask = AgentTask(title: "Completed thread", goal: "Write a demo app for onboarding", workspace: deliveredWorkspace)
        deliveredTask.status = .completed
        context.insert(deliveredWorkspace)
        context.insert(deliveredTask)
        _ = try TaskWorkspaceAccess(task: deliveredTask).ensureTaskFolder()
        try context.save()

        let activePrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: activeTask)
        // Sanity check: this goal wording actually triggers the directive for
        // a still-active task, so the absence below is meaningful.
        #expect(activePrompt.contains("Artifact delivery contract:"))

        let deliveredPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: deliveredTask)
        // `TaskOutputFolderSectionProvider` is a separate section provider from
        // `FollowUpIntroSectionProvider` -- suppressing the artifact contract
        // there alone left this one still telling the provider its first
        // action must be creating/updating the already-delivered artifact
        // (adversarial finding).
        #expect(!deliveredPrompt.contains("Artifact delivery contract:"))
    }

    @Test("the Approved goal Thread Intent line is suppressed once its goal is demoted")
    func approvedGoalLineSuppressedOnceDemoted() throws {
        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "approved-goal-suppressed")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Approved Goal Suppressed", primaryPath: root)
        let task = AgentTask(title: "Completed thread", goal: "Ship the release notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        // Approving reconciles `state.objective.approvedGoal` to the plan's
        // goal, which equals `task.goal` here -- the common case
        // (ChatPanelView syncs `task.goal = plan.goal` on approval).
        let plan = TaskPlanPayload(
            title: "Release notes plan",
            goal: "Ship the release notes",
            steps: [TaskPlanPayloadStep(id: "s1", title: "Write the notes")]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        task.status = .completed
        try context.save()

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)

        // `FollowUpIntroSectionProvider` demotes the same text to "already
        // delivered -- background context only" framing; the Thread Intent
        // block must not then re-anchor the provider by also asserting
        // "Approved goal: Ship the release notes" as if it were still live
        // (adversarial finding).
        #expect(prompt.contains("already delivered"))
        #expect(!prompt.contains("- Approved goal: Ship the release notes"))
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

    @Test("a persisted Tier 2 pivot is ignored when Objective Drift Detection is off")
    func persistedPivotIgnoredWhenDriftDetectionDisabled() throws {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(false, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "toggle-off-read-path")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Toggle Off Read Path", primaryPath: root)
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: folder))
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Rework the CSV exporter instead",
            assessedAtTurn: 4,
            inputHash: "hash-toggle-off-read-path"
        )
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)

        // Regression guard (adversarial finding): the read path must check the
        // setting itself rather than rely solely on write-side cleanup landing
        // in time -- this simulates the one-turn window where a stale pivot is
        // still on disk while the setting already reads as off.
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)
        #expect(prompt.contains("Goal: Write the onboarding guide"))
        #expect(prompt.contains("- Current objective: Write the onboarding guide"))
        #expect(!prompt.contains("Rework the CSV exporter instead"))
        #expect(!prompt.contains("superseded"))
    }

    @Test("an approved plan with a different goal invalidates a stale Tier 2 pivot")
    func approvedPlanGoalInvalidatesStaleSupersededVerdict() throws {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.objectiveDriftDetectionEnabled
        let original = defaults.object(forKey: key) as? Bool
        defaults.set(true, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let container = try makeFollowUpGoalFramingContainer()
        let context = container.mainContext
        let root = try Self.temporaryRoot(name: "approved-plan-invalidates")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Approved Plan Invalidates", primaryPath: root)
        let task = AgentTask(title: "Running thread", goal: "Write the onboarding guide", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        TaskContextStateManager.refresh(task: task)
        var state = try #require(TaskContextStateManager.load(taskFolder: folder))
        // An earlier, informal-drift Tier 2 pivot from before any plan existed.
        state.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "An earlier, now-stale drift-episode objective",
            assessedAtTurn: 2,
            inputHash: "hash-before-plan-approved"
        )
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)

        // The thread later moves into an approved, durable plan with its own,
        // different goal -- reconciled by Tier 1 without ever going through an
        // explicit "your goal is..." marker message, so `supersedesOriginalGoal`
        // stays false on this path (adversarial finding: the reconciler must not
        // rely on that flag alone to detect Tier 1 has already moved on, or it
        // re-overwrites a freshly-correct plan-reconciled objective with stale
        // Tier 2 text on every subsequent refresh).
        let plan = TaskPlanPayload(
            title: "Onboarding v2",
            goal: "Ship the redesigned onboarding flow",
            steps: [TaskPlanPayloadStep(id: "s1", title: "Do work")]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Thanks, one more thing", task: task)

        #expect(!prompt.contains("An earlier, now-stale drift-episode objective"))
        #expect(prompt.contains("- Current objective: Ship the redesigned onboarding flow"))
    }

    private static func temporaryRoot(name: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-follow-up-goal-framing-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
