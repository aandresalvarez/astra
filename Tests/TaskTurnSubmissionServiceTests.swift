import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRACore
@testable import ASTRA

@Suite("Task turn submission")
@MainActor
struct TaskTurnSubmissionServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("Submission atomically persists the message and waiting request")
    func submissionPersistsMessageAndRequest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Follow up", goal: "Persist before admission")
        context.insert(task)
        try context.save()

        let result = TaskTurnSubmissionService.submit(
            message: "  Please continue safely.  ",
            for: task,
            into: context,
            at: Date(timeIntervalSince1970: 1_000)
        )
        guard case let .success(submission) = result else {
            Issue.record("Expected durable submission")
            return
        }

        let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>())
        let events = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(requests.count == 1)
        #expect(events.count == 1)
        #expect(requests[0].id == submission.requestID)
        #expect(requests[0].messageEventID == submission.eventID)
        #expect(requests[0].state == .waitingForWorker)
        #expect(requests[0].sequence == 1)
        #expect(events[0].id == submission.eventID)
        #expect(events[0].payload == "Please continue safely.")
        #expect(try TaskTurnRequestRepository.requests(for: task, in: context).map(\.id) == [submission.requestID])
    }

    @Test("Requests retain FIFO order and only allow guarded transitions")
    func requestsUseFifoAndGuardedTransitions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "FIFO", goal: "Keep turns ordered")
        context.insert(task)

        let first = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1)
        let second = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2)
        context.insert(second)
        context.insert(first)
        try context.save()

        #expect(try TaskTurnRequestRepository.activeRequests(for: task, in: context).map(\.id) == [first.id, second.id])
        let admitted = TaskTurnRequestStateMachine.transition(first, to: .admitted)
        #expect(admitted.changed)
        #expect(first.admittedAt != nil)
        let illegal = TaskTurnRequestStateMachine.transition(first, to: .completed)
        #expect(!illegal.changed)
        #expect(illegal.rejection == .illegalTransition(from: .admitted, to: .completed))
    }

    @Test("Every new submission snapshots the RESOLVED runtime, even for nil or unrecognized task runtimes")
    func submissionSnapshotsResolvedRuntimeForLegacyTasks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Legacy", goal: "Resolve the runtime")
        // Legacy rows can carry a nil runtime; `resolvedRuntimeID` is what
        // actually launches, so the snapshot must record it — a nil snapshot
        // is reserved for rows migrated from V15.
        task.runtimeID = nil
        context.insert(task)

        let nilRuntime = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1)
        #expect(nilRuntime.runtimeIDSnapshot == TaskExecutionDefaults.runtime.rawValue)
        #expect(nilRuntime.runtimeIDSnapshot != nil)

        // AgentRuntimeID is an open string identifier: resolution defaults
        // only for nil/empty, and a non-empty unrecognized value passes
        // through — it is exactly what resolvedRuntimeID would hand the
        // launcher, so the snapshot stores it verbatim.
        task.runtimeID = "ghost-runtime"
        let unrecognized = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2)
        #expect(unrecognized.runtimeIDSnapshot == "ghost-runtime")

        task.runtimeID = "   "
        let blankRuntime = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 4)
        #expect(blankRuntime.runtimeIDSnapshot == TaskExecutionDefaults.runtime.rawValue)

        task.runtimeID = AgentRuntimeID.codexCLI.rawValue
        let recognized = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 3)
        #expect(recognized.runtimeIDSnapshot == AgentRuntimeID.codexCLI.rawValue)
        #expect(recognized.modelSnapshot == task.model)
        #expect(recognized.tokenBudgetSnapshot == task.tokenBudget)
        #expect(recognized.executionPolicySnapshot != nil)
    }

    @Test("Applying launch-input snapshots restores composer edits made while the request waited")
    func applyLaunchInputSnapshotsRestoresSubmissionConfiguration() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Snapshot", goal: "Launch as advertised")
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        task.model = "claude-sonnet-4-6"
        task.tokenBudget = 100_000
        task.testCommand = "swift test"
        context.insert(task)
        try context.save()

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Run with the settings I sent",
            for: task,
            into: context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))

        // Composer edits landing while the request waits in the queue.
        task.runtimeID = AgentRuntimeID.codexCLI.rawValue
        task.runtimeExplicitlySelected = true
        task.model = "gpt-5-codex"
        task.tokenBudget = 999
        task.maxTurns = 7
        task.isolationStrategy = .copy
        task.validationStrategy = .runTests
        task.testCommand = "make check"
        task.useAgentTeam = true
        task.teamSize = 5
        task.teamInstructions = "split the work"
        task.skillSnapshotsJSON = "[{\"edited\":true}]"
        task.runtimePermissionGrantsJSON = "[{\"granted\":\"later\"}]"

        #expect(request.applyLaunchInputSnapshots(to: task))

        #expect(task.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(task.runtimeExplicitlySelected == false)
        #expect(task.model == "claude-sonnet-4-6")
        #expect(task.tokenBudget == 100_000)
        #expect(task.maxTurns == 0)
        #expect(task.isolationStrategy == .sameDirectory)
        #expect(task.validationStrategy == .manual)
        #expect(task.testCommand == "swift test")
        #expect(task.useAgentTeam == false)
        #expect(task.teamSize == 3)
        #expect(task.teamInstructions.isEmpty)
        #expect(task.skillSnapshotsJSON == "[]")
        #expect(task.runtimePermissionGrantsJSON == "[]")

        // Idempotent: a second application finds nothing left to restore.
        #expect(!request.applyLaunchInputSnapshots(to: task))

        // A request never applies onto a task it does not own.
        let other = AgentTask(title: "Other", goal: "Unrelated")
        other.model = "gpt-5-codex"
        context.insert(other)
        #expect(!request.applyLaunchInputSnapshots(to: other))
        #expect(other.model == "gpt-5-codex")
    }

    @Test("Migrated V15 rows with nil snapshots leave the task's launch inputs untouched")
    func applyLaunchInputSnapshotsPreservesFallbackForMigratedRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Migrated", goal: "Keep fallback")
        context.insert(task)

        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1)
        context.insert(request)
        // Simulate a row migrated from V15: launch inputs were never captured.
        request.runtimeIDSnapshot = nil
        request.modelSnapshot = nil
        request.tokenBudgetSnapshot = nil
        request.executionPolicySnapshotJSON = nil

        task.runtimeID = AgentRuntimeID.codexCLI.rawValue
        task.model = "gpt-5-codex"
        task.tokenBudget = 555
        task.maxTurns = 9

        #expect(!request.applyLaunchInputSnapshots(to: task))
        #expect(task.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(task.model == "gpt-5-codex")
        #expect(task.tokenBudget == 555)
        #expect(task.maxTurns == 9)
    }
}

private extension Result where Failure == TaskTurnSubmissionService.SubmissionError {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
