import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

private func makeTaskStateMachineContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task State Machine")
@MainActor
struct TaskStateMachineTests {
    @Test("User submission queues a draft task")
    func userSubmissionQueuesDraftTask() throws {
        let container = try makeTaskStateMachineContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Draft", goal: "Run me")
        context.insert(task)
        let now = Date(timeIntervalSince1970: 1_000)

        let result = TaskStateMachine.enqueueFromUserSubmission(
            task,
            modelContext: context,
            at: now
        )

        #expect(result.changed)
        #expect(result.from == .draft)
        #expect(result.to == .queued)
        #expect(result.rejection == nil)
        #expect(task.status == .queued)
        #expect(task.updatedAt == now)
        #expect(task.completedAt == nil)
        #expect(task.unreadAt == nil)
    }

    @Test("Queued task admission moves task to running")
    func queuedTaskAdmissionMovesTaskToRunning() throws {
        let container = try makeTaskStateMachineContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Queued", goal: "Run me")
        task.status = .queued
        task.completedAt = Date(timeIntervalSince1970: 900)
        context.insert(task)
        let now = Date(timeIntervalSince1970: 1_000)

        let result = TaskStateMachine.admitQueuedTaskToRuntime(
            task,
            modelContext: context,
            at: now
        )

        #expect(result.changed)
        #expect(result.from == .queued)
        #expect(result.to == .running)
        #expect(task.status == .running)
        #expect(task.updatedAt == now)
        #expect(task.completedAt == nil)
        #expect(task.unreadAt == nil)
    }

    @Test("Runtime session start only confirms an admitted running task")
    func runtimeSessionStartOnlyConfirmsAdmittedRunningTask() throws {
        let container = try makeTaskStateMachineContainer()
        let context = container.mainContext
        let rejectedStatuses: [TaskStatus] = [.draft, .queued, .pendingUser]

        for status in rejectedStatuses {
            let task = AgentTask(title: "Not admitted", goal: "Run me")
            task.status = status
            context.insert(task)

            let result = TaskStateMachine.markRuntimeSessionStarted(
                task,
                modelContext: context,
                at: Date(timeIntervalSince1970: 1_000)
            )

            #expect(!result.changed)
            #expect(result.from == status)
            #expect(result.to == .running)
            #expect(result.rejection == .illegalTransition)
            #expect(task.status == status)
        }

        let admitted = AgentTask(title: "Admitted", goal: "Already running")
        admitted.status = .running
        context.insert(admitted)

        let result = TaskStateMachine.markRuntimeSessionStarted(
            admitted,
            modelContext: context,
            at: Date(timeIntervalSince1970: 2_000)
        )

        #expect(!result.changed)
        #expect(result.from == .running)
        #expect(result.to == .running)
        #expect(result.rejection == nil)
        #expect(admitted.status == .running)
    }

    @Test("Illegal runtime admission is rejected without mutation")
    func illegalRuntimeAdmissionIsRejectedWithoutMutation() throws {
        let container = try makeTaskStateMachineContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Completed", goal: "Already done")
        task.status = .completed
        let completedAt = Date(timeIntervalSince1970: 900)
        task.completedAt = completedAt
        context.insert(task)

        let result = TaskStateMachine.admitQueuedTaskToRuntime(
            task,
            modelContext: context,
            at: Date(timeIntervalSince1970: 1_000)
        )

        #expect(!result.changed)
        #expect(result.from == .completed)
        #expect(result.to == .running)
        #expect(result.rejection == .illegalTransition)
        #expect(task.status == .completed)
        #expect(task.completedAt == completedAt)
    }

    @Test("Runtime completion marks task completed and unread")
    func runtimeCompletionMarksTaskCompletedAndUnread() throws {
        let container = try makeTaskStateMachineContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Running", goal: "Finish")
        task.status = .running
        context.insert(task)
        let now = Date(timeIntervalSince1970: 1_000)

        let result = TaskStateMachine.completeFromRuntime(
            task,
            modelContext: context,
            at: now
        )

        #expect(result.changed)
        #expect(result.from == .running)
        #expect(result.to == .completed)
        #expect(task.status == .completed)
        #expect(task.updatedAt == now)
        #expect(task.completedAt == now)
        #expect(task.unreadAt == now)
    }

    @Test("Continuation admission failure restores previous terminal status")
    func continuationAdmissionFailureRestoresPreviousTerminalStatus() throws {
        let container = try makeTaskStateMachineContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Follow-up", goal: "Continue")
        task.status = .completed
        let completedAt = Date(timeIntervalSince1970: 800)
        task.completedAt = completedAt
        context.insert(task)
        let snapshot = TaskStateMachine.snapshot(task)

        let admitted = TaskStateMachine.admitContinuationToRuntime(
            task,
            modelContext: context,
            at: Date(timeIntervalSince1970: 900)
        )
        #expect(admitted.changed)
        #expect(task.status == .running)
        #expect(task.completedAt == nil)

        let restored = TaskStateMachine.restoreContinuationAdmissionFailure(
            task,
            snapshot: snapshot,
            modelContext: context,
            at: Date(timeIntervalSince1970: 1_000)
        )

        #expect(restored.changed)
        #expect(restored.from == .running)
        #expect(restored.to == .completed)
        #expect(task.status == .completed)
        #expect(task.completedAt == completedAt)
        #expect(task.unreadAt != nil)
    }
}
