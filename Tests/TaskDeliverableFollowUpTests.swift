import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// A follow-up after the task's request was met does not owe the original
/// deliverable again, and a task pinned to a worktree is reported where its
/// code runs.
///
/// Repro from 2026-10-07: a task pinned to `issue-479/wt-a` created
/// notes-a.txt and completed. A follow-up committed it, the commit landed,
/// and the run still ended `no_usable_result` with "did not create the
/// requested file: notes-a.txt", listing the workspace root, not the worktree.
@Suite("Task deliverable follow-up turns")
@MainActor
struct TaskDeliverableFollowUpTests {
    @Test("a follow-up after the task completed does not owe the original deliverable")
    func turnAfterCompletionDoesNotOweOriginalDeliverable() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        try fixture.writeNotes(modifiedAt: firstRun.startedAt.addingTimeInterval(5))

        let commitRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(commitRun, with: TaskEventTypes.Conversation.userMessage.rawValue,
                         payload: "git add notes-a.txt && git commit -m 'Add notes A'; git log --oneline -2")

        #expect(TaskDeliverableExpectation.requiresDeliverableArtifact(fixture.task))
        #expect(!TaskDeliverableExpectation.owesDeliverable(fixture.task, run: commitRun))
        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: commitRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(result.canComplete)
        #expect(result.status == "not_applicable")
        #expect(TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: commitRun).canComplete)

        // The review dock agrees once the follow-up completes.
        fixture.task.status = .completed
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(task: fixture.task, latestRun: commitRun))
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(try fixture.reviewInput()))
    }

    @Test("the first turn still owes its named deliverable")
    func firstTurnStillOwesDeliverable() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: firstRun))
        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: firstRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(!result.canComplete)
        #expect(result.level == .noArtifact)
        #expect(result.checks.contains { $0.id == "artifact.required_files" && $0.summary.contains("notes-a.txt") })
    }

    @Test("a retry or follow-up before the deliverable was ever produced still owes it")
    func turnsBeforeDeliveryStillOwe() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let failedRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))
        failedRun.status = .failed
        failedRun.stopReason = TaskRunStopReason.noUsableResult.rawValue

        let retryRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-300))
        fixture.startRun(retryRun, with: TaskEventTypes.ExecutionRequest.retry.rawValue,
                         payload: try fixture.envelope(TaskExecutionSourcePayloadV1(launchMode: .initial)))
        retryRun.status = .failed
        retryRun.stopReason = TaskRunStopReason.noUsableResult.rawValue
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "please try once more")

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: retryRun))
        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: followUpRun))
        #expect(!TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: followUpRun).canComplete)
    }

    @Test("a later approved plan step still owes the task's deliverable")
    func laterPlanStepStillOwes() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        _ = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))

        let stepRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(stepRun, with: TaskEventTypes.ExecutionRequest.planStep.rawValue,
                         payload: try fixture.envelope(TaskExecutionSourcePayloadV1(launchMode: .approvedPlan)))

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: stepRun))
    }

    @Test("a user approval counts as delivery; a runtime permission approval does not")
    func manualApprovalCountsAsDelivery() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let blockedRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))
        blockedRun.status = .failed
        blockedRun.stopReason = TaskRunStopReason.noUsableResult.rawValue
        fixture.recordEvent(TaskEventTypes.Task.approved.rawValue,
                            payload: "Runtime permission approved by user. Continuation queued.",
                            at: Date().addingTimeInterval(-500))
        let resumeRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-300))
        fixture.startRun(resumeRun, with: TaskEventTypes.ExecutionRequest.resume.rawValue,
                         payload: try fixture.envelope(TaskExecutionSourcePayloadV1(launchMode: .continuation, message: "Continue")))
        resumeRun.status = .failed
        resumeRun.stopReason = TaskRunStopReason.noUsableResult.rawValue
        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: resumeRun))

        fixture.recordEvent(TaskEventTypes.Task.approved.rawValue, payload: "Task approved by user.",
                            at: Date().addingTimeInterval(-200))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Commit it.")

        #expect(!TaskDeliverableExpectation.owesDeliverable(fixture.task, run: followUpRun))
    }

    @Test("a publication receipt is not a whole-task approval")
    func publicationReceiptDoesNotCountAsDelivery() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let pendingRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))
        pendingRun.status = .completed
        pendingRun.stopReason = TaskRunStopReason.externalOutcomePending.rawValue
        fixture.recordEvent(TaskEventTypes.Task.approved.rawValue,
                            payload: "Published draft pull request #12: https://example.invalid/pull/12",
                            at: Date().addingTimeInterval(-300))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Thanks, what's left?")

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: followUpRun))
    }

    @Test("a finished plan step is not delivery until the plan finishes")
    func intermediatePlanStepIsNotDelivery() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let stepRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))
        fixture.startRun(stepRun, with: TaskEventTypes.ExecutionRequest.planStep.rawValue,
                         payload: try fixture.envelope(TaskExecutionSourcePayloadV1(launchMode: .approvedPlan)))
        let clarifyRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-300))
        fixture.startRun(clarifyRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Use tabs in step 2.")
        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: clarifyRun))

        fixture.recordEvent(TaskEventTypes.Plan.executionCompleted.rawValue, payload: "{}", at: Date().addingTimeInterval(-200))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Commit it.")
        #expect(!TaskDeliverableExpectation.owesDeliverable(fixture.task, run: followUpRun))
    }

    @Test("an exempt follow-up is not graded on an older task-folder artifact")
    func exemptFollowUpIgnoresStaleArtifacts() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        let stale = (TaskWorkspaceAccess(task: fixture.task).taskFolder as NSString).appendingPathComponent("config.json")
        try "{ not json".write(toFile: stale, atomically: true, encoding: .utf8)
        let earlier = firstRun.startedAt.addingTimeInterval(5)
        try FileManager.default.setAttributes([.creationDate: earlier, .modificationDate: earlier], ofItemAtPath: stale)
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "What did you change?")

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: followUpRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(result.canComplete)
        #expect(result.status == "not_applicable")
        #expect(!result.checks.contains { $0.id == "json.syntax" })
    }

    @Test("the review dock still sees delivery evidence older than the transcript window")
    func reviewDockSeesEvidenceOutsideTheWindow() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        _ = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Commit it.")
        fixture.task.status = .completed

        // A one-run window drops the completed first run from the snapshot.
        let input = try fixture.reviewInput(maxRuns: 1)
        #expect(input.runs.map(\.id) == [followUpRun.id])
        #expect(!input.requiresDeliverableArtifact)
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(input))
        #expect(!TaskDeliverableExpectation.owesDeliverable(fixture.task, run: followUpRun))
    }

    @Test("the store read and the live-model read agree")
    func storeReadMatchesLiveModelRead() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let stepRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-900))
        fixture.startRun(stepRun, with: TaskEventTypes.ExecutionRequest.planStep.rawValue,
                         payload: try fixture.envelope(TaskExecutionSourcePayloadV1(launchMode: .approvedPlan)))
        let clarifyRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))
        fixture.startRun(clarifyRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Use tabs.")
        fixture.recordEvent(TaskEventTypes.Task.approved.rawValue, payload: "Task approved by user.",
                            at: Date().addingTimeInterval(-300))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Commit it.")
        try fixture.context.save()

        for run in [stepRun, clarifyRun, followUpRun] {
            let stored = try TaskDeliverableExpectation.followsUpDeliveredRequest(
                taskID: fixture.task.id, runID: run.id, startedAt: run.startedAt, in: fixture.context
            )
            #expect(stored == TaskDeliverableExpectation.followsUpDeliveredRequest(run, in: fixture.task))
        }
        #expect(!TaskDeliverableExpectation.followsUpDeliveredRequest(clarifyRun, in: fixture.task))
        #expect(TaskDeliverableExpectation.followsUpDeliveredRequest(followUpRun, in: fixture.task))
    }

    @Test("a follow-up after delivery is not told to write the artifact again")
    func deliveredFollowUpPromptDropsArtifactContract() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        fixture.task.status = .running
        try fixture.context.save()
        let message = "git add notes-a.txt && git commit -m 'Add notes A'"

        // Sanity: without the verdict the follow-up prompt carries both contracts.
        let owedPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: message, task: fixture.task)
        #expect(owedPrompt.contains("Artifact first-action requirement:"))
        #expect(owedPrompt.contains("Artifact delivery contract:"))

        var policy = AgentRuntimeExecutionPolicy()
        policy.followsUpDeliveredRequest = true
        let deliveredPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: message,
            task: fixture.task,
            executionPolicy: policy
        )
        #expect(!deliveredPrompt.contains("Artifact first-action requirement:"))
        #expect(!deliveredPrompt.contains("Artifact delivery contract:"))
    }

    @Test("a follow-up after delivery gets no Write bootstrap for the delivered artifact")
    func deliveredFollowUpGetsNoWriteBootstrap() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let tools = (allowed: ["Read", "Glob", "Grep"], askFirst: ["Write", "Edit", "Bash"])

        #expect(ProviderArtifactBootstrapPolicy.launchTools(
            task: fixture.task, followsUpDeliveredRequest: false, permissionPolicy: .restricted,
            providerAllowedTools: tools.allowed, askFirstTools: tools.askFirst
        ) == ["Write"])
        #expect(ProviderArtifactBootstrapPolicy.launchTools(
            task: fixture.task, followsUpDeliveredRequest: true, permissionPolicy: .restricted,
            providerAllowedTools: tools.allowed, askFirstTools: tools.askFirst
        ).isEmpty)
        #expect(ProviderArtifactBootstrapPolicy.persistedLaunchTools(
            task: fixture.task, followsUpDeliveredRequest: true, permissionPolicy: .restricted,
            providerAllowedTools: ["Read", "Write"], askFirstTools: tools.askFirst
        ).isEmpty)
    }

    @Test("the delivery verdict survives the provider render the adapters launch with")
    func verdictSurvivesProviderRender() {
        var policy = AgentRuntimeExecutionPolicy()
        policy.followsUpDeliveredRequest = true
        let render = ProviderPolicyRender(
            providerID: .claudeCode, adapterVersion: 1, policyLevel: .review, configOwnership: .generated,
            permissionMode: .restricted, allowedTools: ["Read"], runtimeSupportTools: [], askFirstTools: ["Write"],
            deniedTools: [], allowedShellPatterns: [], askFirstShellPatterns: [], deniedShellPatterns: [],
            allowedURLPatterns: [], deniedURLPatterns: [], cliArgumentsSummary: [], settingsSummary: "test",
            generatedConfigPreview: "", enforcementTiers: [.providerNative], diagnostics: [],
            usesBroadProviderPermissions: false
        )

        #expect(policy.applyingProviderRender(render).followsUpDeliveredRequest)
        #expect(!AgentRuntimeExecutionPolicy().applyingProviderRender(render).followsUpDeliveredRequest)
    }

    @Test("a follow-up after delivery gets the informational progress window")
    func deliveredFollowUpGetsInformationalTimeout() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }

        #expect(AgentRuntimeProgressTimeoutPolicy.semanticProgressTimeout(
            task: fixture.task, phase: .resume, idleTimeoutSeconds: 180
        ) == 360)
        #expect(AgentRuntimeProgressTimeoutPolicy.semanticProgressTimeout(
            task: fixture.task, phase: .resume, idleTimeoutSeconds: 180, followsUpDeliveredRequest: true
        ) == 180)
    }

    @Test("an exempt follow-up is still checked on a file it recorded writing, whatever its timestamp")
    func exemptFollowUpChecksRecordedFiles() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        _ = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Copy the config in.")
        // `cp -p` keeps the source's old modification date.
        let copied = (TaskWorkspaceAccess(task: fixture.task).taskFolder as NSString).appendingPathComponent("config.json")
        try "{ not json".write(toFile: copied, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-7_200)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: copied)
        followUpRun.appendFileChange(StoredFileChange(
            path: copied, changeType: StoredFileChangeKind.write.rawValue, content: nil,
            oldString: nil, newString: nil, timestamp: Date()
        ))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: followUpRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(!result.canComplete)
        #expect(result.checks.contains { $0.id == "json.syntax" && $0.status == .failed })
    }

    @Test("a relative recorded write is the file under the run's working root, not a same-named one elsewhere")
    func relativeRecordedWriteResolvesAgainstWorkingRoot() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        _ = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Write config.json.")
        let old = Date().addingTimeInterval(-7_200)
        let stale = (TaskWorkspaceAccess(task: fixture.task).taskFolder as NSString).appendingPathComponent("config.json")
        try "{ not json".write(toFile: stale, atomically: true, encoding: .utf8)
        let written = (fixture.worktree as NSString).appendingPathComponent("config.json")
        try #"{"ready":true}"#.write(toFile: written, atomically: true, encoding: .utf8)
        for path in [stale, written] {
            try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: path)
        }
        followUpRun.appendFileChange(StoredFileChange(
            path: "config.json", changeType: StoredFileChangeKind.write.rawValue, content: nil,
            oldString: nil, newString: nil, timestamp: Date()
        ))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task, run: followUpRun, modelContext: fixture.context, workspacePath: fixture.worktree
        )
        #expect(result.canComplete)
        #expect(result.evidencePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == [URL(fileURLWithPath: written).resolvingSymlinksInPath().path])
    }

    @Test("an observed task-folder change counts even with a preserved timestamp")
    func observedChangeCountsAsRunEvidence() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        _ = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        let followUpRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.startRun(followUpRun, with: TaskEventTypes.Conversation.userMessage.rawValue, payload: "cp -p the config in.")
        let copied = (TaskWorkspaceAccess(task: fixture.task).taskFolder as NSString).appendingPathComponent("config.json")
        try "{ not json".write(toFile: copied, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-7_200)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: copied)
        followUpRun.appendFileChange(StoredFileChange(
            path: "config.json", changeType: StoredFileChangeKind.discovered.rawValue, content: nil,
            oldString: nil, newString: nil, timestamp: Date()
        ))
        #expect(followUpRun.fileChanges.isEmpty)

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task, run: followUpRun, modelContext: fixture.context, workspacePath: fixture.worktree
        )
        #expect(!result.canComplete)
        #expect(result.checks.contains { $0.id == "json.syntax" && $0.status == .failed })
    }

    @Test("a pinned task's missing-deliverable message names the worktree, not the workspace")
    func pinnedTaskMessageNamesWorktree() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: firstRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(result.summary.contains("- Working directory: \(fixture.worktree)"))
        #expect(!result.summary.contains("Workspace root: \(fixture.workspaceRoot)"))

        // The completion gate has no execution path to hand in; it names the
        // code working directory the pin resolves to.
        let decision = TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: firstRun)
        let message = try #require(decision.userVisibleMessage)
        #expect(message.contains("- Working directory: \(fixture.worktree)"))
        #expect(message.contains("Task output folder: \(TaskWorkspaceAccess(task: fixture.task).taskFolder)"))
        #expect(!message.contains("Workspace root: \(fixture.workspaceRoot)"))
    }

    @Test("an unpinned task's missing-deliverable message still names the workspace root")
    func unpinnedTaskMessageNamesWorkspaceRoot() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        fixture.task.executionRootPath = nil

        let message = TaskDeliverableExpectation.missingDeliverableMessage(for: fixture.task)

        #expect(message.contains("- Workspace root: \(fixture.workspaceRoot)"))
        #expect(!message.contains("Working directory"))
    }
}

@MainActor
private final class DeliverableFollowUpFixture {
    let root: String
    let workspaceRoot: String
    let worktree: String
    let container: ModelContainer
    let context: ModelContext
    let task: AgentTask

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-deliverable-follow-up-\(UUID().uuidString)", isDirectory: true)
        root = base.path
        workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true).path
        worktree = base.appendingPathComponent("issue-479/wt-a", isDirectory: true).path
        for path in [workspaceRoot, worktree] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        let workspace = Workspace(name: "Follow-up", primaryPath: workspaceRoot)
        task = AgentTask(
            title: "Notes A",
            goal: """
            Create notes-a.txt containing task-a in the working directory.
            Then run: sleep 45; echo task-a > notes-a.txt; pwd; ls
            """,
            workspace: workspace
        )
        task.executionRootPath = worktree
        context.insert(workspace)
        context.insert(task)
        try TaskWorkspaceAccess(task: task).ensureTaskFolder()
    }

    func removeFiles() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func makeRun(startedAt: Date) -> TaskRun {
        let run = TaskRun(task: task)
        run.startedAt = startedAt
        run.completedAt = startedAt.addingTimeInterval(20)
        run.status = .completed
        run.stopReason = TaskRunStopReason.completed.rawValue
        context.insert(run)
        return run
    }

    /// The request's source event, linked to the run that carried it out.
    func startRun(_ run: TaskRun, with type: String, payload: String) {
        let event = TaskEvent(task: task, type: type, payload: payload, run: run)
        event.timestamp = run.startedAt.addingTimeInterval(-1)
        context.insert(event)
    }

    func recordEvent(_ type: String, payload: String, at date: Date) {
        let event = TaskEvent(task: task, type: type, payload: payload)
        event.timestamp = date
        context.insert(event)
    }

    func envelope(_ payload: TaskExecutionSourcePayloadV1) throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    func writeNotes(modifiedAt date: Date) throws {
        let notes = (worktree as NSString).appendingPathComponent("notes-a.txt")
        try "task-a\n".write(toFile: notes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: notes)
    }

    /// The dock's input with the verdict `recomputeDecisionOutcomes` caches,
    /// over a transcript window of `maxRuns`.
    func reviewInput(maxRuns: Int = 50) throws -> PendingTaskReviewSnapshotInput {
        try context.save()
        let snapshot = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task, maxRuns: maxRuns))
        let latestRun = try #require(snapshot.latestRun)
        let followsUp = try TaskDeliverableExpectation.followsUpDeliveredRequest(
            taskID: task.id,
            runID: latestRun.id,
            startedAt: latestRun.startedAt,
            in: context
        )
        return PendingTaskReviewSnapshotInput(
            task: task,
            snapshot: snapshot,
            deliveredRequestFollowUpRunID: followsUp ? latestRun.id : nil
        )
    }
}
