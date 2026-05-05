import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskRunLifecycleContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task Run Lifecycle")
@MainActor
struct TaskRunLifecycleServiceTests {
    @Test("User cancellation finalizes running runs for any runtime")
    func userCancellationFinalizesRunningRunsForAnyRuntime() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Runtime neutral", goal: "Cancel every provider run")
        task.status = .running
        context.insert(task)

        let claudeRun = TaskRun(task: task)
        claudeRun.runtimeID = AgentRuntimeID.claudeCode.rawValue
        claudeRun.startedAt = now.addingTimeInterval(-20)
        context.insert(claudeRun)

        let copilotRun = TaskRun(task: task)
        copilotRun.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        copilotRun.startedAt = now.addingTimeInterval(-10)
        context.insert(copilotRun)
        try context.save()

        let summary = TaskRunLifecycleService.cancelTask(
            task,
            modelContext: context,
            source: .userAction,
            at: now
        )

        #expect(summary.tasksUpdated == 1)
        #expect(summary.runsUpdated == 2)
        #expect(summary.eventsInserted == 1)
        #expect(task.status == .cancelled)
        #expect(task.completedAt == now)
        #expect(claudeRun.status == .cancelled)
        #expect(copilotRun.status == .cancelled)
        #expect(claudeRun.completedAt == now)
        #expect(copilotRun.completedAt == now)
        #expect(claudeRun.stopReason == "cancelled")
        #expect(copilotRun.stopReason == "cancelled")
        #expect(task.events.contains { $0.type == "task.cancelled" && $0.run?.id == copilotRun.id })
    }

    @Test("Coordinator cancellation persists run cancellation")
    func coordinatorCancellationPersistsRunCancellation() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Cancel", goal: "Cancel from UI")
        task.status = .running
        context.insert(task)

        let run = TaskRun(task: task)
        run.runtimeID = "future_provider"
        context.insert(run)
        try context.save()

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.cancelTask(task)

        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.completedAt != nil)
        #expect(run.stopReason == "cancelled")
        #expect(task.events.contains { $0.type == "task.cancelled" })
    }

    @Test("Startup recovery cancels orphaned running task and run")
    func startupRecoveryCancelsOrphanedRunningTaskAndRun() throws {
        let recoveredAt = Date(timeIntervalSince1970: 2_000)
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Orphan", goal: "Was running before restart")
        task.status = .running
        context.insert(task)

        let run = TaskRun(task: task)
        run.runtimeID = AgentRuntimeID.claudeCode.rawValue
        context.insert(run)
        try context.save()

        let summary = TaskRunLifecycleService.recoverOrphanedRunningRuns(
            modelContext: context,
            at: recoveredAt
        )

        #expect(summary.tasksUpdated == 1)
        #expect(summary.runsUpdated == 1)
        #expect(task.status == .cancelled)
        #expect(task.completedAt == recoveredAt)
        #expect(run.status == .cancelled)
        #expect(run.completedAt == recoveredAt)
        #expect(run.stopReason == "app_restarted")
        #expect(task.events.contains { $0.type == "task.interrupted" && $0.run?.id == run.id })
    }

    @Test("Startup recovery repairs running run on already cancelled task")
    func startupRecoveryRepairsRunningRunOnAlreadyCancelledTask() throws {
        let recoveredAt = Date(timeIntervalSince1970: 3_000)
        let originalCompletedAt = Date(timeIntervalSince1970: 2_900)
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Cancelled", goal: "Parent already cancelled")
        task.status = .cancelled
        task.completedAt = originalCompletedAt
        context.insert(task)

        let run = TaskRun(task: task)
        run.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        context.insert(run)
        try context.save()

        let summary = TaskRunLifecycleService.recoverOrphanedRunningRuns(
            modelContext: context,
            at: recoveredAt
        )

        #expect(summary.tasksUpdated == 0)
        #expect(summary.runsUpdated == 1)
        #expect(task.status == .cancelled)
        #expect(task.completedAt == originalCompletedAt)
        #expect(run.status == .cancelled)
        #expect(run.completedAt == recoveredAt)
        #expect(run.stopReason == "app_restarted")
        #expect(task.events.contains { $0.type == "task.interrupted" && $0.run?.id == run.id })
    }

    @Test("Startup recovery leaves completed runs alone")
    func startupRecoveryLeavesCompletedRunsAlone() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Done", goal: "Already done")
        task.status = .completed
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.completedAt = Date(timeIntervalSince1970: 4_000)
        context.insert(run)
        try context.save()

        let summary = TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: context)

        #expect(summary.hasChanges == false)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
    }

    @Test("Superseded run finalization does not change terminal task status")
    func supersededRunDoesNotChangeTerminalTaskStatus() throws {
        let finishedAt = Date(timeIntervalSince1970: 5_000)
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Follow-up", goal: "Continue")
        task.status = .failed
        context.insert(task)

        let run = TaskRun(task: task)
        run.runtimeID = "future_provider"
        context.insert(run)
        try context.save()

        let summary = TaskRunLifecycleService.cancelTask(
            task,
            modelContext: context,
            source: .supersededByNewRun,
            at: finishedAt
        )

        #expect(summary.tasksUpdated == 0)
        #expect(summary.runsUpdated == 1)
        #expect(task.status == .failed)
        #expect(task.completedAt == nil)
        #expect(run.status == .cancelled)
        #expect(run.completedAt == finishedAt)
        #expect(run.stopReason == "superseded")
        #expect(task.events.contains { $0.type == "task.interrupted" && $0.run?.id == run.id })
    }
}
