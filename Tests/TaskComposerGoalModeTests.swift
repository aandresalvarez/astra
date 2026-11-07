import Foundation
import SwiftUI
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task composer Goal mode", .serialized)
@MainActor
struct TaskComposerGoalModeTests {
    @Test("Captured Goal bindings follow another window's durable Consult selection")
    func capturedBindingsFollowSavedMode() throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6")
        task.status = .completed
        try harness.context.save()
        let otherWindowTask = try #require(harness.context.model(for: task.persistentModelID) as? AgentTask)
        #expect(otherWindowTask === task)

        // Both windows share the durable task and keep independent Goal toggles.
        // Capture their bindings before the other window changes that task.
        var firstGoal = true
        var secondGoal = false
        let first = ComposerToolbar.goalModeBinding(for: task,
            selection: Binding(get: { firstGoal }, set: { firstGoal = $0 }))
        let second = ComposerToolbar.goalModeBinding(for: otherWindowTask,
            selection: Binding(get: { secondGoal }, set: { secondGoal = $0 }))
        #expect(first.wrappedValue && !second.wrappedValue)

        TaskWorkspaceConsultationPolicy.select(true, for: otherWindowTask, in: harness.context,
            persist: { try harness.context.save() })
        #expect(TaskWorkspaceConsultationPolicy.isEnabled(for: task))
        #expect(!first.wrappedValue && !second.wrappedValue)
        #expect(firstGoal, "Masking a stale preference must not create a second durable owner")
        #expect(!TaskWorkspaceConsultationPolicy.goalModeSelection(for: task, localSelection: firstGoal))
        second.wrappedValue = true
        #expect(!secondGoal, "A captured setter cannot enable Goal while Consult is selected")

        TaskWorkspaceConsultationPolicy.select(false, for: otherWindowTask, in: harness.context,
            persist: { try harness.context.save() })
        #expect(first.wrappedValue && !second.wrappedValue)
        second.wrappedValue = true
        #expect(secondGoal && second.wrappedValue)
        first.wrappedValue = false
        #expect(!firstGoal && !first.wrappedValue)
    }

    @Test("A planning submission rechecks Consult before any acceptance side effects")
    func consultationRejectsStalePlanningSubmission() throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Plan the work", model: "claude-sonnet-4-6")
        task.status = .completed
        try harness.context.save()
        let composer = TaskComposerDraft()
        composer.text = "Plan the work"
        var attachments = ["synthetic-reference.md"]
        #expect(TaskWorkspaceConsultationPolicy.goalModeSelection(for: task, localSelection: true))

        // The rendered Goal action is now stale. The acceptance boundary must
        // consult the current task, independently of that earlier decision.
        TaskWorkspaceConsultationPolicy.select(true, for: task, in: harness.context,
            persist: { try harness.context.save() })
        let eventIDs = Set(task.events.map(\.id))
        var launched = false
        let accepted = TaskWorkspaceConsultationPolicy.acceptPlanningSubmission(for: task) {
            harness.context.insert(TaskEvent(task: task, type: TaskPlanConversationEventTypes.userMessage,
                payload: composer.text))
            launched = true
            composer.text = ""
            attachments = []
            return true
        }
        #expect(!accepted && !launched)
        #expect(Set(task.events.map(\.id)) == eventIDs)
        #expect(composer.text == "Plan the work")
        #expect(attachments == ["synthetic-reference.md"])
        #expect(TaskPlanService.reconstruct(for: task).plan == nil)
    }

    @Test("Work planning accepted before Consult can finish after the selection changes")
    func acceptedWorkPlanningCanFinish() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Plan the work", model: "claude-sonnet-4-6")
        task.status = .completed
        try harness.context.save()
        let plan = TaskPlanPayload(title: "Accepted Work plan", goal: task.goal,
            steps: [TaskPlanPayloadStep(id: "inspect", title: "Inspect the workspace")])
        var completion: Task<Void, Error>?
        var launchCount = 0
        let accepted = try TaskWorkspaceConsultationPolicy.acceptPlanningSubmission(for: task) {
            harness.context.insert(TaskEvent(task: task, type: TaskPlanConversationEventTypes.userMessage,
                payload: "Plan the work"))
            try harness.context.save()
            launchCount += 1
            // This synthetic response is scheduled after synchronous acceptance,
            // as in TaskMainView. It does not invoke a provider or open a window.
            completion = Task { @MainActor in
                #expect(TaskWorkspaceConsultationPolicy.isEnabled(for: task))
                harness.context.insert(TaskEvent(task: task, type: TaskPlanConversationEventTypes.assistantMessage,
                    payload: "Accepted planning response"))
                TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
                try harness.context.save()
            }
            return true
        }
        #expect(accepted && launchCount == 1)
        #expect(task.events.filter { $0.type == TaskPlanConversationEventTypes.userMessage }.count == 1)

        TaskWorkspaceConsultationPolicy.select(true, for: task, in: harness.context,
            persist: { try harness.context.save() })
        let acceptedCompletion = try #require(completion)
        try await acceptedCompletion.value
        #expect(TaskPlanService.reconstruct(for: task).plan?.planID == plan.planID)
        #expect(task.events.filter { $0.type == TaskPlanConversationEventTypes.assistantMessage }.count == 1)
        #expect(TaskWorkspaceConsultationPolicy.isEnabled(for: task))

        let nextAccepted = TaskWorkspaceConsultationPolicy.acceptPlanningSubmission(for: task) {
            launchCount += 1
            return true
        }
        #expect(!nextAccepted && launchCount == 1)
    }
}
