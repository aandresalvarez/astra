import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Existing-task approved plan actions", .serialized)
@MainActor
struct TaskApprovedPlanRunCommandTests {
    @Test("New approved-plan actions require the saved Work selection",
          arguments: [TaskPlanExecutionMode.fullPlan, .nextStep],
          ["consult_plain", "consult_command", "work_plain", "work_command"])
    func newPlanActionUsesCurrentMode(mode: TaskPlanExecutionMode, scenario: String) throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Follow the approved plan", model: "claude-sonnet-4-6")
        task.status = .completed
        task.completedAt = Date(timeIntervalSince1970: 1_000)
        task.unreadAt = Date(timeIntervalSince1970: 1_001)
        let consultation = scenario.hasPrefix("consult")
        let hasCommands = scenario.hasSuffix("command")
        var plan = TaskPlanPayload(title: "Existing plan", goal: task.goal,
            steps: [.init(id: "inspect", title: "Inspect the workspace")])
        if hasCommands {
            plan.validationContract = .init(assertions: [.init(id: "validate", description: "Synthetic command",
                method: .command, command: "make test")])
        }
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        try harness.context.save()

        // The existing task has an enabled approved-plan action when rendered.
        // Another window then changes the same saved task before the click.
        let renderedEnabled = TaskApprovedPlanRunCommand.isEnabled(for: task, hasQueue: true)
        #expect(renderedEnabled)
        let otherWindowTask = try #require(harness.context.model(for: task.persistentModelID) as? AgentTask)
        TaskWorkspaceConsultationPolicy.select(consultation, for: otherWindowTask, in: harness.context,
            persist: { try harness.context.save() })
        #expect(TaskApprovedPlanRunCommand.isEnabled(for: task, hasQueue: true) == !consultation)
        let stateBefore = TaskStateMachine.snapshot(task)
        let updatedBefore = task.updatedAt
        let unreadBefore = task.unreadAt
        let titleBefore = task.title
        let goalBefore = task.goal
        let eventIDsBefore = Set(task.events.map(\.id))
        let requestsBefore = try harness.context.fetchCount(FetchDescriptor<TaskTurnRequest>())
        let approvalsBefore = task.events.filter { $0.type == TaskPlanEventTypes.approved }.count
        var policyCalls = 0
        var readOnlyBlocks: [String] = []

        let result = TaskApprovedPlanRunCommand.submit(plan: plan, mode: mode, task: task,
            modelContext: harness.context, hasQueue: true,
            recordReadOnlyBlock: { readOnlyBlocks.append($0) },
            recordAdditionalPolicy: { policyCalls += 1 })

        #expect(readOnlyBlocks.isEmpty)
        if consultation {
            #expect(result == nil)
            #expect(policyCalls == 0)
            #expect(TaskStateMachine.snapshot(task) == stateBefore)
            #expect(task.updatedAt == updatedBefore && task.unreadAt == unreadBefore)
            #expect(task.title == titleBefore && task.goal == goalBefore)
            #expect(Set(task.events.map(\.id)) == eventIDsBefore)
            #expect(try harness.context.fetchCount(FetchDescriptor<TaskTurnRequest>()) == requestsBefore)
            #expect(task.events.filter { $0.type == TaskPlanEventTypes.approved }.count == approvalsBefore)
        } else {
            let submitted = try #require(result)
            let submission = try submitted.get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
            let source = try #require(task.events.first { $0.id == submission.eventID })
            let payload = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(source))
            #expect(policyCalls == 1 && task.status == .queued)
            #expect(try harness.context.fetchCount(FetchDescriptor<TaskTurnRequest>()) == requestsBefore + 1)
            #expect(task.events.filter { $0.type == TaskPlanEventTypes.approved }.count == approvalsBefore + 1)
            #expect(request.kind == .planStep && request.state == .waitingForWorker)
            #expect(payload.launchMode == .approvedPlan && payload.planExecutionMode == mode)
            #expect(payload.planSnapshot == plan)
            #expect(request.resourceClaims.contains { $0.kind == .workspace && $0.access == .exclusive })
            #expect(request.resourceClaims.allSatisfy { $0.readConsistency != .live })

            // Model a later persisted mode edit. The accepted request still owns its launch settings.
            let claims = request.resourceClaimsJSON
            let policy = request.executionPolicySnapshotJSON
            TaskWorkspaceConsultationPolicy.apply(true, to: task)
            try harness.context.save()
            #expect(!TaskApprovedPlanRunCommand.isEnabled(for: task, hasQueue: true))
            #expect(!TaskWorkspaceConsultationPolicy.isRequired(by: request, task: task))
            #expect(request.resourceClaimsJSON == claims)
            #expect(request.executionPolicySnapshotJSON == policy)
            #expect(ExecutionRequestSubmissionService.decodeSourcePayload(source) == payload)
        }
    }
}
