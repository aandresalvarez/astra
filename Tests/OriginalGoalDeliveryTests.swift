import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeOriginalGoalDeliveryContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Original goal delivery classifier")
@MainActor
struct OriginalGoalDeliveryTests {
    @Test("plan-less thread completed via task.status is delivered")
    func planLessCompletedTaskIsDelivered() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "No plan thread", goal: "Answer a quick question")
        task.status = .completed
        context.insert(task)

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .delivered)
    }

    @Test("plan-less thread still running is active")
    func planLessRunningTaskIsActive() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "No plan thread", goal: "Answer a quick question")
        task.status = .running
        context.insert(task)

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)
    }

    @Test("executing plan without contract outcome is active")
    func executingPlanIsActive() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Executing plan", goal: "Ship the feature")
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Feature plan",
            goal: "Ship the feature",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Do the work")]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: plan.planID, task: task, modelContext: context)

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)
    }

    @Test("blocked task (pending user) is active")
    func blockedPendingUserTaskIsActive() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Blocked thread", goal: "Deploy the change")
        task.status = .pendingUser
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Deploy plan",
            goal: "Deploy the change",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Run deploy")]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: plan.planID, task: task, modelContext: context)

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)
    }

    @Test("failed task is active")
    func failedTaskIsActive() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Failed thread", goal: "Migrate the database")
        task.status = .failed
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Migration plan",
            goal: "Migrate the database",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Run migration")]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: plan.planID, task: task, modelContext: context)
        TaskPlanService.recordExecutionFailed(planID: plan.planID, task: task, modelContext: context, reason: "Migration script errored")

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)
    }

    @Test("plan lifecycle completed is delivered even when task.status lags")
    func planLifecycleCompletedIsDelivered() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Completed plan thread", goal: "Refactor the module")
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Refactor plan",
            goal: "Refactor the module",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Refactor")]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: plan.planID, task: task, modelContext: context)
        TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: context)

        #expect(task.status != .completed)
        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .delivered)
    }

    @Test("passed validation contract for the current plan is delivered")
    func passedValidationContractIsDelivered() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Validated thread", goal: "Prove the fix works")
        context.insert(task)

        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Proof plan",
            goal: "Prove the fix works",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "required-proof",
                    description: "Required proof passes",
                    method: .command,
                    command: "swift test"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: planID, task: task, modelContext: context)

        let payload = TaskValidationContractEventPayload(
            version: 1,
            planID: planID,
            status: "passed",
            requiredPassed: 1,
            requiredTotal: 1,
            failedRequiredAssertionIDs: [],
            summary: "Validation contract passed."
        )
        let data = try JSONEncoder().encode(payload)
        context.insert(TaskEvent(
            task: task,
            type: TaskValidationEventTypes.contractPassed,
            payload: String(data: data, encoding: .utf8) ?? "{}"
        ))
        try context.save()

        #expect(task.status != .completed)
        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .delivered)
    }

    @Test("overridden validation contract for the current plan is delivered")
    func overriddenValidationContractIsDelivered() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Overridden thread", goal: "Ship despite a flaky check")
        task.status = .pendingUser
        context.insert(task)

        let planID = UUID(uuidString: "7F6E52B6-78EF-54F4-8AFC-4EB7E69F5C80") ?? UUID()
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Override plan",
            goal: "Ship despite a flaky check",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "required-proof",
                    description: "Required proof passes",
                    method: .command,
                    command: "swift test"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: planID, task: task, modelContext: context)

        let failedPayload = TaskValidationContractEventPayload(
            version: 1,
            planID: planID,
            status: "failed",
            requiredPassed: 0,
            requiredTotal: 1,
            failedRequiredAssertionIDs: ["required-proof"],
            summary: "Validation contract failed: 1 required assertion did not pass."
        )
        let failedData = try JSONEncoder().encode(failedPayload)
        context.insert(TaskEvent(
            task: task,
            type: TaskValidationEventTypes.contractFailed,
            payload: String(data: failedData, encoding: .utf8) ?? "{}"
        ))

        let overriddenPayload = TaskValidationContractEventPayload(
            version: 1,
            planID: planID,
            status: "overridden",
            requiredPassed: 0,
            requiredTotal: 1,
            failedRequiredAssertionIDs: ["required-proof"],
            summary: "Validation contract overridden by user approval."
        )
        let overriddenData = try JSONEncoder().encode(overriddenPayload)
        context.insert(TaskEvent(
            task: task,
            type: TaskValidationEventTypes.contractOverridden,
            payload: String(data: overriddenData, encoding: .utf8) ?? "{}"
        ))
        try context.save()

        #expect(task.status != .completed)
        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .delivered)
    }

    @Test("failed validation contract alone (no override) stays active")
    func failedValidationContractWithoutOverrideStaysActive() throws {
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Failing thread", goal: "Prove the fix works")
        task.status = .pendingUser
        context.insert(task)

        let planID = UUID()
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Proof plan",
            goal: "Prove the fix works",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "required-proof",
                    description: "Required proof passes",
                    method: .command,
                    command: "swift test"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        TaskPlanService.recordExecutionStarted(planID: planID, task: task, modelContext: context)

        let payload = TaskValidationContractEventPayload(
            version: 1,
            planID: planID,
            status: "failed",
            requiredPassed: 0,
            requiredTotal: 1,
            failedRequiredAssertionIDs: ["required-proof"],
            summary: "Validation contract failed: 1 required assertion did not pass."
        )
        let data = try JSONEncoder().encode(payload)
        context.insert(TaskEvent(
            task: task,
            type: TaskValidationEventTypes.contractFailed,
            payload: String(data: data, encoding: .utf8) ?? "{}"
        ))
        try context.save()

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)
    }

    @Test("manual task approval is delivered even after status resets to running")
    func manuallyApprovedTaskIsDeliveredAfterStatusResets() throws {
        // Mirrors TaskLifecycleCoordinator.approveTask: sets task.status =
        // .completed and records a "task.approved" event, with no plan or
        // validation-contract event at all (the common plan-less review case).
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Manually approved thread", goal: "Answer a quick question")
        task.status = .completed
        context.insert(task)
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.approved,
            payload: "Task approved by user."
        ))

        // Sending a follow-up message resets task.status to .running
        // (TaskMainView.sendConversationMessage) before the next prompt is
        // built -- the manual approval event is the only durable evidence
        // left that the original goal was already delivered (adversarial
        // finding).
        task.status = .running

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .delivered)
    }

    @Test("a runtime permission approval event alone is not mistaken for manual completion")
    func runtimePermissionApprovalIsNotMistakenForCompletion() throws {
        // approveSimilarRuntimePermissionForTask / approveRuntimePermissionAndContinue
        // record the SAME "task.approved" event type but leave task.status ==
        // .running -- the payload wording is the only thing distinguishing
        // this from a genuine completion approval.
        let container = try makeOriginalGoalDeliveryContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Permission-only thread", goal: "Answer a quick question")
        task.status = .running
        context.insert(task)
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.approved,
            payload: "Runtime permission approved by user. Continuing with one-time expanded provider permissions."
        ))

        #expect(TaskContextStateManager.originalGoalDelivery(for: task) == .active)
    }
}
