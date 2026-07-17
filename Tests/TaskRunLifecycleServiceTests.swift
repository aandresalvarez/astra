import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
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
        let blockedDecision = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)
        #expect(blockedDecision.shouldBlockCompletion)
        #expect(blockedDecision.stopReason == "no_usable_result")

        try "<html></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run))
        #expect(TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run).canComplete)
    }

    @Test("Misspelled HTML slide deck request still requires artifact")
    func misspelledHTMLSlideDeckRequestStillRequiresArtifact() {
        let task = AgentTask(
            title: "cerate a html slide deck",
            goal: "cerate a html slide deck about agents lanscape in the 2030"
        )

        #expect(TaskDeliverableExpectation.requiresStandaloneArtifact(task))
    }

    @Test("Misspelled JavaScript page build request still requires artifact")
    func misspelledJavaScriptPageBuildRequestStillRequiresArtifact() {
        let task = AgentTask(
            title: "buid a rubis cuve solved in 3d in ajavascript page",
            goal: "buid a rubis cuve solved in 3d in ajavascript page"
        )

        #expect(TaskDeliverableExpectation.requiresStandaloneArtifact(task))
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

    @Test("Coordinator approval records explicit override for failed validation contracts")
    func coordinatorApprovalRecordsValidationOverride() throws {
        let root = NSTemporaryDirectory() + "task-lifecycle-validation-override-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Override", primaryPath: root)
        context.insert(workspace)
        let task = AgentTask(
            title: "Validated result",
            goal: "Close a failed validation result",
            workspace: workspace
        )
        task.status = .pendingUser
        context.insert(task)
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Proof plan",
            goal: "Close a failed validation result",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Do work")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "required-proof",
                    description: "Required proof passes",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
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

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        coordinator.approveTask(task)

        #expect(task.status == .completed)
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.contractOverridden &&
                $0.payload.contains("\"status\":\"overridden\"")
        })
        #expect(task.events.contains {
            $0.type == "task.approved" &&
                $0.payload.contains("despite a failed required validation contract")
        })
        TaskContextStateManager.refresh(task: task)
        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.validationContract?.status == "overridden")
        #expect(state.verification.status == "overridden")
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

    @Test("Review policy requests artifact evidence only for eligible deliverable states")
    func reviewPolicyDefersArtifactEvidenceUntilNeeded() {
        let completedRun = PendingTaskReviewRunSnapshot(
            id: UUID(),
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 110),
            stopReason: "completed"
        )
        let irrelevantStatuses: [TaskStatus] = [
            .draft, .queued, .running, .failed, .cancelled, .budgetExceeded
        ]

        for status in irrelevantStatuses {
            #expect(!PendingTaskReviewPolicy.requiresScopedArtifactEvidence(
                taskStatus: status,
                isTaskDone: false,
                requiresDeliverableArtifact: true,
                latestRun: completedRun,
                runs: [completedRun],
                events: []
            ))
        }
        #expect(!PendingTaskReviewPolicy.requiresScopedArtifactEvidence(
            taskStatus: .pendingUser,
            isTaskDone: false,
            requiresDeliverableArtifact: false,
            latestRun: completedRun,
            runs: [completedRun],
            events: []
        ))
        #expect(PendingTaskReviewPolicy.requiresScopedArtifactEvidence(
            taskStatus: .pendingUser,
            isTaskDone: false,
            requiresDeliverableArtifact: true,
            latestRun: completedRun,
            runs: [completedRun],
            events: []
        ))

        let policyBlockedRun = PendingTaskReviewRunSnapshot(
            id: UUID(),
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 120),
            completedAt: Date(timeIntervalSince1970: 130),
            stopReason: "policy_violation"
        )
        #expect(!PendingTaskReviewPolicy.requiresScopedArtifactEvidence(
            taskStatus: .pendingUser,
            isTaskDone: false,
            requiresDeliverableArtifact: true,
            latestRun: policyBlockedRun,
            runs: [policyBlockedRun],
            events: []
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

    @Test("Completed misspelled artifact task remains attention worthy")
    func completedMisspelledArtifactTaskRemainsAttentionWorthy() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let workspacePath = NSTemporaryDirectory() + "completed-empty-artifact-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workspacePath) }
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Artifact Review", primaryPath: workspacePath)
        let task = AgentTask(
            title: "cerate a html slide deck",
            goal: "cerate a html slide deck about agents lanscape in the 2030",
            workspace: workspace
        )
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()

        #expect(PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(task: task, latestRun: run))
        task.isDone = true
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(task: task, latestRun: run))
    }

    @Test("Completed artifact attention ignores older task-folder artifacts")
    func completedArtifactAttentionIgnoresOlderTaskFolderArtifacts() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let workspacePath = NSTemporaryDirectory() + "completed-stale-artifact-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workspacePath) }
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Artifact Review", primaryPath: workspacePath)
        let task = AgentTask(
            title: "Create page",
            goal: "create an html web page",
            workspace: workspace
        )
        task.status = .completed
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let oldArtifactURL = URL(fileURLWithPath: taskFolder).appendingPathComponent("index.html")
        try "<html>old</html>".write(to: oldArtifactURL, atomically: true, encoding: .utf8)
        let now = Date()
        let oldDate = now.addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldArtifactURL.path)

        let priorRun = TaskRun(task: task)
        priorRun.status = .completed
        priorRun.startedAt = oldDate.addingTimeInterval(-5)
        priorRun.completedAt = oldDate.addingTimeInterval(5)
        priorRun.stopReason = "completed"

        let latestRun = TaskRun(task: task)
        latestRun.status = .completed
        latestRun.startedAt = now.addingTimeInterval(30)
        latestRun.completedAt = now.addingTimeInterval(40)
        latestRun.stopReason = "completed"
        context.insert(priorRun)
        context.insert(latestRun)
        try context.save()

        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: latestRun))
        #expect(!TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: latestRun))
        #expect(PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(task: task, latestRun: latestRun))
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

    @Test("Startup recovery preserves completed work awaiting typed publication")
    func startupRecoveryPreservesPendingPublicationReview() throws {
        let container = try makeTaskRunLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(
            title: "Publish",
            goal: "Implement the fix and create a pull request"
        )
        task.status = .pendingUser
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 4_000)
        run.typedStopReason = .externalOutcomePending
        context.insert(run)

        let request = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(
                kind: .githubPullRequest,
                runID: run.id,
                message: "Review the exact proposal."
            ),
            run: run
        )
        context.insert(request)
        try context.save()

        let summary = TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: context)

        #expect(!summary.hasChanges)
        #expect(task.status == .pendingUser)
        #expect(run.status == .completed)
        #expect(run.typedStopReason == .externalOutcomePending)
        #expect(TaskExternalOutcomeRequirementResolver.hasPendingGitHubPullRequest(task: task))
        #expect(!task.events.contains { $0.type == TaskEventTypes.Task.interrupted.rawValue })
    }

    @Test("Startup recovery preserves waiting external task and operation registration")
    func startupRecoveryPreservesWaitingExternalOperation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-waiting-external-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")
        let taskID: UUID
        let runID: UUID
        let operationID: UUID

        do {
            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = container.mainContext
            let task = AgentTask(title: "External", goal: "Wait for the managed job")
            task.status = .waitingExternal
            let run = TaskRun(task: task)
            run.status = .completed
            run.completedAt = Date(timeIntervalSince1970: 4_000)
            run.typedStopReason = .externalOutcomePending
            let operation = TaskExternalOperation(
                taskID: task.id,
                externalIdentity: "\(WorkspaceManagedJobStartReceipt.backend):\(task.id.uuidString.lowercased()):\(run.id.uuidString.lowercased()):job-restart",
                originatingRunID: run.id,
                backendKindRaw: WorkspaceManagedJobStartReceipt.backend,
                backendJobID: "job-restart",
                nextCheckAt: Date(timeIntervalSince1970: 4_100)
            )
            context.insert(task)
            context.insert(run)
            context.insert(operation)
            try context.save()
            taskID = task.id
            runID = run.id
            operationID = operation.id
        }

        let reopened = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = reopened.mainContext
        let summary = TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: context)
        let task = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        let operation = try #require(try context.fetch(FetchDescriptor<TaskExternalOperation>()).first)

        #expect(!summary.hasChanges)
        #expect(task.id == taskID)
        #expect(task.status == .waitingExternal)
        #expect(task.completedAt == nil)
        #expect(task.runs.first?.id == runID)
        #expect(task.runs.first?.status == .completed)
        #expect(task.runs.first?.typedStopReason == .externalOutcomePending)
        #expect(operation.id == operationID)
        #expect(operation.taskID == taskID)
        #expect(operation.monitoringState == .active)
        #expect(operation.nextCheckAt == Date(timeIntervalSince1970: 4_100))
        #expect(!task.events.contains { $0.type == TaskEventTypes.Task.interrupted.rawValue })
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
