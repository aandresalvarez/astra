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

    @Test("Coordinator dismisses unusable pending result without completing task")
    func coordinatorDismissesUnusablePendingResultWithoutCompletingTask() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Web page", goal: "write a web page with html and javascript")
        task.status = .pendingUser
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "no_usable_result"
        context.insert(run)
        try context.save()

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.approveTask(task)

        #expect(task.status == .pendingUser)
        #expect(task.isDone == true)
        #expect(task.completedAt == nil)
        #expect(task.events.contains { $0.type == "task.dismissed" })
        #expect(!task.events.contains { $0.type == "task.approved" })
    }

    @Test("Task folder runtime files do not satisfy standalone artifact requirement")
    func taskFolderRuntimeFilesDoNotSatisfyStandaloneArtifactRequirement() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-runtime-files-artifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Artifact", primaryPath: root.path)
        let task = AgentTask(
            title: "Web page",
            goal: "write a web page with html and javascript",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "state".write(
            toFile: (taskFolder as NSString).appendingPathComponent(TaskContextStateManager.markdownFileName),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            toFile: (taskFolder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName),
            atomically: true,
            encoding: .utf8
        )
        try "history".write(
            toFile: (taskFolder as NSString).appendingPathComponent("session_history.md"),
            atomically: true,
            encoding: .utf8
        )
        try "turn".write(
            toFile: (taskFolder as NSString).appendingPathComponent("outputs/turn_001.md"),
            atomically: true,
            encoding: .utf8
        )

        #expect(TaskDeliverableExpectation.requiresStandaloneArtifact(task))
        #expect(!TaskDeliverableExpectation.hasArtifact(for: task, run: run))

        try "<html></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run))
    }

    @Test("Coordinator approval completes generic failed pending tasks")
    func coordinatorApprovalCompletesGenericFailedPendingTasks() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Review result", goal: "Summarize the repository")
        task.status = .pendingUser
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "failed"
        context.insert(run)
        try context.save()

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.approveTask(task)

        #expect(task.status == .completed)
        #expect(task.isDone == false)
        #expect(task.completedAt != nil)
        #expect(task.events.contains { $0.type == "task.approved" })
        #expect(!task.events.contains { $0.type == "task.dismissed" })
    }

    @Test("Coordinator approval completes stale no-usable-result when artifact requirement no longer applies")
    func coordinatorApprovalCompletesStaleNoUsableResultWhenArtifactRequirementNoLongerApplies() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(
            title: "Fork of Fork of question about the process",
            goal: TaskPromptFixtures.scaffoldedZipStatusGoal
        )
        task.status = .pendingUser
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "no_usable_result"
        run.output = "BRIE full de-identification batch SUCCEEDED."
        context.insert(run)
        try context.save()

        #expect(PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: run) == nil)

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.approveTask(task)

        #expect(task.status == .completed)
        #expect(task.completedAt != nil)
        #expect(task.events.contains { $0.type == "task.approved" })
        #expect(!task.events.contains { $0.type == "task.dismissed" })
    }

    @Test("Coordinator approval completes pending tasks without runs")
    func coordinatorApprovalCompletesPendingTasksWithoutRuns() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Manual review", goal: "Review notes")
        task.status = .pendingUser
        context.insert(task)
        try context.save()

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.approveTask(task)

        #expect(task.status == .completed)
        #expect(task.completedAt != nil)
        #expect(task.events.contains { $0.type == "task.approved" })
        #expect(!task.events.contains { $0.type == "task.dismissed" })
    }

    @Test("Coordinator dismisses policy-blocked pending result without completing task")
    func coordinatorDismissesPolicyBlockedPendingResultWithoutCompletingTask() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy block", goal: "List protected resource")
        task.status = .pendingUser
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "policy_violation"
        context.insert(run)
        try context.save()

        #expect(PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: run) == .policyBlocked)
        #expect(PendingTaskReviewPolicy.reviewState(for: task, latestRun: run) == PendingTaskReviewState(
            isDismissed: false,
            dismissalReason: .policyBlocked
        ))

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.approveTask(task)

        #expect(task.status == .pendingUser)
        #expect(task.isDone == true)
        #expect(task.completedAt == nil)
        #expect(task.events.contains { $0.type == "task.dismissed" && $0.run?.id == run.id })
        #expect(!task.events.contains { $0.type == "task.approved" })
        #expect(PendingTaskReviewPolicy.isDismissed(task: task, latestRun: run))
        #expect(PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: run) == nil)
        #expect(PendingTaskReviewPolicy.reviewState(for: task, latestRun: run) == PendingTaskReviewState(
            isDismissed: true,
            dismissalReason: nil
        ))

        let retryRun = TaskRun(task: task)
        retryRun.status = .failed
        retryRun.startedAt = run.startedAt.addingTimeInterval(60)
        retryRun.stopReason = "policy_violation"
        context.insert(retryRun)
        try context.save()

        #expect(!PendingTaskReviewPolicy.isDismissed(task: task, latestRun: retryRun))
        #expect(PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: retryRun) == .policyBlocked)
        #expect(PendingTaskReviewPolicy.reviewState(for: task, latestRun: retryRun) == PendingTaskReviewState(
            isDismissed: false,
            dismissalReason: .policyBlocked
        ))
    }

    @Test("Pending task review policy maps legacy dismissal to original run only")
    func pendingTaskReviewPolicyMapsLegacyDismissalToOriginalRunOnly() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Legacy policy block", goal: "List protected resource")
        task.status = .pendingUser
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .failed
        run.startedAt = Date(timeIntervalSince1970: 1_000)
        run.stopReason = "policy_violation"
        context.insert(run)

        let legacyDismissal = TaskEvent(
            task: task,
            type: "task.dismissed",
            payload: "Task dismissed by user without marking it completed."
        )
        legacyDismissal.timestamp = run.startedAt.addingTimeInterval(30)
        context.insert(legacyDismissal)
        try context.save()

        #expect(PendingTaskReviewPolicy.reviewState(for: task, latestRun: run) == PendingTaskReviewState(
            isDismissed: true,
            dismissalReason: nil
        ))

        let retryRun = TaskRun(task: task)
        retryRun.status = .failed
        retryRun.startedAt = run.startedAt.addingTimeInterval(60)
        retryRun.stopReason = "policy_violation"
        context.insert(retryRun)
        try context.save()

        #expect(PendingTaskReviewPolicy.reviewState(for: task, latestRun: retryRun) == PendingTaskReviewState(
            isDismissed: false,
            dismissalReason: .policyBlocked
        ))
    }

    @Test("Pending task review policy dismisses completed artifact tasks missing files")
    func pendingTaskReviewPolicyDismissesCompletedArtifactTasksMissingFiles() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let workspacePath = NSTemporaryDirectory() + "pending-artifact-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workspacePath) }
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Artifact Review", primaryPath: workspacePath)
        let task = AgentTask(title: "Create page", goal: "create an html web page", workspace: workspace)
        task.status = .pendingUser
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()

        #expect(PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: run) == .missingRequiredArtifact)
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

    @Test("Startup recovery can skip workspace auto-export")
    func startupRecoveryCanSkipWorkspaceAutoExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-run-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "No Export", primaryPath: root.path)
        context.insert(workspace)
        let task = AgentTask(title: "Orphan", goal: "Was running", workspace: workspace)
        task.status = .running
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        try context.save()

        let summary = TaskRunLifecycleService.recoverOrphanedRunningRuns(
            modelContext: context,
            autoExportWorkspaces: false
        )

        let configPath = root.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName).path
        #expect(summary.hasChanges)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: configPath))
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
