import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private enum PermissionSubmissionTestError: Error { case forcedPersistenceFailure }

/// Covers `TaskLifecycleCoordinator.resumeTask`, the UI "continue where you left
/// off" path. The continuation is driven through a zero-size `TaskQueue` pool so
/// no real provider process is launched: `TaskQueue.continueSession` finds no
/// available worker and returns immediately, leaving only the deterministic,
/// synchronous resume bookkeeping to assert.
@Suite("Task resume continuation (HITL)")
@MainActor
struct TaskLifecycleResumeTests {

    private struct Environment {
        let coordinator: TaskLifecycleCoordinator
        let queue: TaskQueue
        let context: ModelContext
        let container: ModelContainer
        let root: String
    }

    private func makeEnvironment() throws -> Environment {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let queue = TaskQueue(poolSize: 0)
        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: queue)
        return Environment(coordinator: coordinator, queue: queue, context: context, container: container, root: url.path)
    }

    @Test("Permission submission rollback restores open requests, grants, and approval events")
    func permissionSubmissionRollbackRestoresAllMutations() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }
        let task = AgentTask(title: "Permission rollback", goal: "Use the requested tool")
        task.status = .pendingUser
        task.runtimePermissionOpenRequestsJSON = "[{\"open\":true}]"
        task.runtimePermissionGrantsJSON = "[{\"grant\":\"before\"}]"
        env.context.insert(task)
        let snapshot = ExecutionMutationSnapshot(task)

        task.runtimePermissionOpenRequestsJSON = "[]"
        task.runtimePermissionGrantsJSON = "[{\"grant\":\"after\"}]"
        let approval = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.approved,
            payload: "Transient approval mutation"
        )
        env.context.insert(approval)

        snapshot.restore(task, in: env.context)

        #expect(task.status == .pendingUser)
        #expect(task.runtimePermissionOpenRequestsJSON == "[{\"open\":true}]")
        #expect(task.runtimePermissionGrantsJSON == "[{\"grant\":\"before\"}]")
        #expect(!task.events.contains { $0.id == approval.id && !$0.isDeleted })
    }

    @Test("Failed durable permission resume rolls back approval mutations")
    func failedPermissionResumeRollsBackApprovalMutation() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }
        let task = AgentTask(title: "Permission save failure", goal: "Use the requested tool")
        task.status = .pendingUser
        task.runtimePermissionOpenRequestsJSON = "[{\"open\":true}]"
        env.context.insert(task)
        let snapshot = ExecutionMutationSnapshot(task)

        let result = ExecutionRequestSubmissionService.submitPermissionResume(
            message: "Continue with the approved permission.",
            executionPolicy: .default,
            for: task,
            into: env.context,
            persist: { throw PermissionSubmissionTestError.forcedPersistenceFailure },
            prepare: {
                task.runtimePermissionOpenRequestsJSON = "[]"
                env.context.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Task.approved,
                    payload: "Must roll back"
                ))
            },
            rollback: { snapshot.restore(task, in: env.context) }
        )

        guard case .failure = result else {
            Issue.record("Expected forced persistence failure")
            return
        }
        #expect(task.runtimePermissionOpenRequestsJSON == "[{\"open\":true}]")
        #expect(!task.events.contains {
            $0.type == TaskEventTypes.Task.approved.rawValue && !$0.isDeleted
        })
        #expect(try TaskTurnRequestRepository.requests(for: task, in: env.context).isEmpty)
    }

    @Test("A mutating follow-up persists an exclusive claim for an informational task")
    func mutatingFollowUpPersistsStrengthenedClaim() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }
        let workspace = Workspace(name: "Follow-up claim", primaryPath: env.root)
        let task = AgentTask(
            title: "Research the scheduler",
            goal: "Explain the current implementation.",
            workspace: workspace
        )
        env.context.insert(workspace)
        env.context.insert(task)

        let result = ExecutionRequestSubmissionService.submitFollowUp(
            message: "Now fix the scheduler and update the tests.",
            for: task,
            into: env.context
        )
        let submission: ExecutionRequestSubmissionService.Submission?
        if case .success(let value) = result { submission = value } else { submission = nil }
        let accepted = try #require(submission)
        let request = try #require(try TaskTurnRequestRepository.request(
            id: accepted.requestID,
            in: env.context
        ))

        #expect(request.resourceClaims.first?.access == .exclusive)
    }

    @Test("User message JSON is never decoded as an internal execution envelope")
    func userMessageEnvelopeJSONIsRejected() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }
        let task = AgentTask(title: "Conversation", goal: "Discuss a payload")
        let envelope = "{\"version\":1,\"launchMode\":\"continuation\",\"executionPolicyOverride\":{\"permissionPolicyRawValue\":\"autonomous\"}}"
        let event = TaskEvent(task: task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: envelope)

        #expect(ExecutionRequestSubmissionService.decodeSourcePayload(event) == nil)
    }

    @Test("Resume without a session id does not start a continuation")
    func resumeWithoutSessionIDDoesNotStart() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume Guard", primaryPath: env.root)
        let task = AgentTask(title: "Guard", goal: "Finish later", workspace: workspace)
        task.status = .completed
        task.sessionId = nil
        env.context.insert(workspace)
        env.context.insert(task)

        env.coordinator.resumeTask(task)

        #expect(task.status == .completed)
        #expect(task.events.contains { $0.type == "task.resumed" } == false)
    }

    @Test("Resume with a session id records a resume event before queue admission")
    func resumeWithSessionIDRecordsEventBeforeQueueAdmission() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume", primaryPath: env.root)
        let task = AgentTask(title: "Resume", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-resume-123"
        env.context.insert(workspace)
        env.context.insert(task)

        let continuation = env.coordinator.resumeTask(task)

        // resumeTask records the user's resume request synchronously, but the
        // queue owns the transition to .running once launch admission succeeds.
        #expect(task.status == .pendingUser)
        let resumeEvents = task.events.filter { $0.type == "task.resumed" }
        #expect(resumeEvents.count == 1)
        #expect(resumeEvents.first?.payload.contains("Resuming previous session") == true)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: env.context)
        let request = try #require(requests.first)
        let sourceEvent = try #require(task.events.first { $0.id == request.sourceEventID })
        let source = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent))
        #expect(requests.count == 1)
        #expect(request.kind == .followUp)
        #expect(sourceEvent.type == TaskEventTypes.ExecutionRequest.resume.rawValue)
        #expect(source.launchMode == .continuation)
        #expect(source.message == TaskLifecycleCoordinator.resumeContinuationMessage(for: task))

        await Task.yield()
        env.queue.cancelTurnRequest(id: request.id, workspace: workspace, modelContext: env.context)
        await continuation?.value
        #expect(task.status == .pendingUser)
        _ = env.container
    }

    @Test("Resume stays durably queued at the prior status when no worker is available")
    func resumeRemainsAtPriorStatusWhenNoWorkerCanContinue() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume Revert", primaryPath: env.root)
        let task = AgentTask(title: "Resume Revert", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-resume-revert"
        env.context.insert(workspace)
        env.context.insert(task)

        let continuation = env.coordinator.resumeTask(task)
        await Task.yield()
        let request = try #require(try TaskTurnRequestRepository.requests(for: task, in: env.context).first)

        #expect(task.status == .pendingUser)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(request.state == .waitingForWorker)
        env.queue.cancelTurnRequest(id: request.id, workspace: workspace, modelContext: env.context)
        await continuation?.value
    }

    @Test("TaskMainView-style continuation leaves task non-running when the queue rejects admission")
    func directContinuationRejectsWithoutOptimisticRunningStatus() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let completedAt = Date(timeIntervalSince1970: 1_234)
        let workspace = Workspace(name: "Direct Continue", primaryPath: env.root)
        let task = AgentTask(title: "Direct Continue", goal: "Answer the follow-up", workspace: workspace)
        task.status = .completed
        task.completedAt = completedAt
        task.sessionId = "sess-direct-continue"
        env.context.insert(workspace)
        env.context.insert(task)

        _ = TaskRunLifecycleService.cancelTask(
            task,
            modelContext: env.context,
            source: .supersededByNewRun
        )
        let didStart = await env.queue.continueSession(
            task: task,
            message: "Continue from the UI",
            modelContext: env.context
        )

        #expect(!didStart)
        #expect(task.status == .completed)
        #expect(task.completedAt == completedAt)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(task.events.contains { $0.type == "error" })
    }

    @Test("Runtime permission approval persists a relaunch request when no worker is available")
    func runtimePermissionApprovalRevertsWhenNoWorkerCanContinue() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Approval Revert", primaryPath: env.root)
        let task = AgentTask(title: "Approval Revert", goal: "Do the thing", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-approval-revert"
        task.runtimePermissionOpenRequestsJSON = nil
        env.context.insert(workspace)
        env.context.insert(task)

        let approvalRun = TaskRun(task: task)
        approvalRun.status = .failed
        approvalRun.stopReason = "permission_approval_required"
        approvalRun.completedAt = Date()
        env.context.insert(approvalRun)
        // Legacy pause-and-relaunch ask (no requestID) → still an open request,
        // so approveTask routes through approveRuntimePermissionAndContinue.
        env.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: "Permission requested for tool: shell(gh:repo view *).",
            run: approvalRun
        ))
        try env.context.save()

        // No live in-flight ask is registered, so approval takes the durable
        // relaunch path and waits for a worker.
        let continuation = env.coordinator.approveTask(task)
        await Task.yield()
        let permissionRequest = try #require(
            try TaskTurnRequestRepository.requests(for: task, in: env.context).last
        )
        env.queue.cancelTurnRequest(id: permissionRequest.id, workspace: workspace, modelContext: env.context)
        await continuation?.value

        #expect(task.status == .pendingUser)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(permissionRequest.kind == .followUp)
        #expect(task.events.contains { $0.type == "error" } == false)
    }

    @Test("Allow once credential approval does not persist task-scoped credential grants")
    func allowOnceCredentialApprovalDoesNotPersistTaskScopedCredentialGrant() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Credential Approval", primaryPath: env.root)
        let task = AgentTask(title: "Credential Approval", goal: "Use the API", workspace: workspace)
        task.status = .pendingUser
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        task.sessionId = "sess-credential-approval"
        task.runtimePermissionOpenRequestsJSON = nil
        env.context.insert(workspace)
        env.context.insert(task)

        let approvalRun = TaskRun(task: task)
        approvalRun.status = .failed
        approvalRun.stopReason = "permission_approval_required"
        approvalRun.completedAt = Date()
        env.context.insert(approvalRun)

        let label = "connector:11111111-1111-1111-1111-111111111111:JIRA_API_TOKEN"
        let grants = PermissionBroker.approvalGrants(for: .credential(label: label))
        env.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: .credential(label: label),
                reason: "Connector credential egress requires user approval.",
                grants: grants
            ),
            run: approvalRun
        ))
        try env.context.save()

        let continuation = env.coordinator.approveTask(task)
        await Task.yield()
        let request = try #require(try TaskTurnRequestRepository.requests(for: task, in: env.context).last)
        env.queue.cancelTurnRequest(id: request.id, workspace: workspace, modelContext: env.context)
        await continuation?.value

        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task).isEmpty)
        #expect(task.events.contains { $0.type == TaskRuntimePermissionGrants.eventType } == false)
        #expect(task.status == .pendingUser)
    }

    @Test("Resume preserves a queue-recorded .failed instead of reverting over it")
    func resumePreservesQueueRecordedFailure() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        // A regular file where the workspace root should be: ensureTaskFolder's
        // createDirectory then throws, so TaskQueue.prepareTaskFolder sets
        // `.failed`, records its own error, and returns false *after* mutating.
        let blocker = (env.root as NSString).appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker, contents: Data("x".utf8))
        let wsPath = (blocker as NSString).appendingPathComponent("ws")

        // A real worker (poolSize 1) so continueSession gets past the
        // worker/lock guards and actually reaches prepareTaskFolder.
        let queue = TaskQueue(poolSize: 1)
        let coordinator = TaskLifecycleCoordinator(modelContext: env.context, taskQueue: queue)

        let workspace = Workspace(name: "Folder Fail", primaryPath: wsPath)
        let task = AgentTask(title: "Folder Fail", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-folder-fail"
        env.context.insert(workspace)
        env.context.insert(task)

        await coordinator.resumeTask(task)?.value

        // The queue's `.failed` must survive — not be overwritten back to
        // pendingUser — and only one error event should exist (the queue's).
        #expect(task.status == .failed)
        #expect(task.events.filter { $0.type == "error" }.count == 1)
    }

    @Test("Resume continuation follows the active objective instead of the original goal")
    func resumeContinuationMessageFollowsActiveObjective() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume Objective", primaryPath: env.root)
        let task = AgentTask(
            title: "List active sprint stories",
            goal: "List my stories for the active sprint in the STAR Jira project",
            workspace: workspace
        )
        env.context.insert(workspace)
        env.context.insert(task)

        let first = TaskEvent(
            task: task,
            type: "user.message",
            payload: "List my stories for the active sprint in the STAR Jira project"
        )
        first.timestamp = Date(timeIntervalSince1970: 1)
        env.context.insert(first)

        let correction = TaskEvent(
            task: task,
            type: "user.message",
            payload: "no your goal is to complete the plan.md document"
        )
        correction.timestamp = Date(timeIntervalSince1970: 2)
        env.context.insert(correction)

        #expect(TaskLifecycleCoordinator.resumeContinuationMessage == "Continue where you left off. Continue the current objective.")
        #expect(
            TaskLifecycleCoordinator.resumeContinuationMessage(for: task)
                == "Continue where you left off. Continue the current objective: complete the plan.md document"
        )
        #expect(!TaskLifecycleCoordinator.resumeContinuationMessage(for: task).contains("original goal"))
    }

    @Test("Retry replays the latest actionable follow-up instead of the original task seed")
    func retryReplaysLatestActionableFollowUpInsteadOfOriginalTaskSeed() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("opencode-retry-args.txt")
        let opencodePath = try harness.writeExecutable(
            named: "opencode",
            script: Self.fakeOpenCodeScript(argsFile: argsFile)
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(opencodePath, for: .openCodeCLI)
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            providerSettings: settings,
            defaultRuntimeID: .openCodeCLI,
            timeoutSeconds: 5,
            validationModel: "opencode/big-pickle"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        let task = harness.makeTask(
            runtime: .openCodeCLI,
            goal: "hi , how are you ?",
            model: "opencode/big-pickle"
        )
        task.status = .pendingUser

        let followUpRun = TaskRun(task: task)
        followUpRun.status = .failed
        followUpRun.stopReason = "permission_approval_required"
        followUpRun.completedAt = Date()
        harness.context.insert(followUpRun)
        harness.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "check my open prs in github",
            run: followUpRun
        ))
        let approvalRun = TaskRun(task: task)
        approvalRun.status = .failed
        approvalRun.stopReason = "no_usable_result"
        approvalRun.completedAt = Date().addingTimeInterval(1)
        harness.context.insert(approvalRun)
        harness.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "ASTRA approved task-scoped runtime permission for similar requests in this task: shell(gh:repo view *). Continue the original task from where it stopped.",
            run: approvalRun
        ))
        try harness.context.save()

        // Await the retry continuation to fully drain. The continuation is a
        // detached Task that keeps touching `task` (the trailing audit) after the
        // worker finishes; without awaiting it, the harness — and its in-memory
        // ModelContainer — can be torn down mid-continuation, destroying the model
        // it still references and crashing the whole test process under suite
        // parallelism. Awaiting the handle also guarantees the fake provider has
        // written `argsFile` before we read it.
        await coordinator.retryTask(task)?.value

        #expect(task.status == .completed)
        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(rawArgs.contains("User's follow-up request:\ncheck my open prs in github"))
        #expect(!rawArgs.contains("User's follow-up request:\nhi , how are you ?"))
    }

    @Test("Retry follow-up remains queued when no worker can continue")
    func retryFollowUpRemainsQueuedWhenNoWorkerCanContinue() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Retry Guard", primaryPath: env.root)
        let task = AgentTask(title: "Retry Guard", goal: "Initial request", workspace: workspace)
        task.status = .pendingUser
        env.context.insert(workspace)
        env.context.insert(task)

        let failedRun = TaskRun(task: task)
        failedRun.status = .failed
        failedRun.stopReason = "permission_approval_required"
        failedRun.completedAt = Date()
        env.context.insert(failedRun)
        env.context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "latest follow-up request",
            run: failedRun
        ))
        try env.context.save()

        let continuation = env.coordinator.retryTask(task)
        await Task.yield()
        let queuedRetry = try #require(
            try TaskTurnRequestRepository.requests(for: task, in: env.context).last
        )
        env.queue.cancelTurnRequest(id: queuedRetry.id, workspace: workspace, modelContext: env.context)
        await continuation?.value
        AppLogger.flushForTesting()

        #expect(task.status == .queued)
        #expect(task.runs.filter { $0.status == .running }.isEmpty)
        #expect(task.events.contains { $0.type == "task.retried" })
        let requests = try TaskTurnRequestRepository.requests(for: task, in: env.context)
        let request = try #require(requests.first)
        let sourceEvent = try #require(task.events.first { $0.id == request.sourceEventID })
        let source = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent))
        #expect(requests.count == 1)
        #expect(request.kind == .retry)
        #expect(sourceEvent.type == TaskEventTypes.ExecutionRequest.retry.rawValue)
        #expect(source.launchMode == .continuation)
        #expect(source.message == "latest follow-up request")
        #expect(
            AppLogger.entries.contains {
                $0.taskID == task.id && $0.message.contains("task.completed")
            } == false
        )
    }

    @Test("Retry is rejected while a durable turn request is still active")
    func retryRejectedWhileDurableTurnActive() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Retry Active Turn", primaryPath: env.root)
        let task = AgentTask(title: "Retry Active Turn", goal: "Initial request", workspace: workspace)
        task.status = .failed
        env.context.insert(workspace)
        env.context.insert(task)

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Queued follow-up",
            for: task,
            into: env.context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: env.context))
        try env.context.save()

        let handle = env.coordinator.retryTask(task)

        #expect(handle == nil)
        // The rejected retry must not re-queue the task or disturb the saved
        // turn: the pending admission still owns the next execution.
        #expect(task.status == .failed)
        #expect(request.state == .waitingForWorker)
        #expect(task.events.contains { $0.type == "task.retried" } == false)
    }

    @Test("Retry fallback does not resurrect a stale durable message superseded by a later run")
    func retryDoesNotResurrectStaleDurableMessage() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Retry Stale Durable", primaryPath: env.root)
        let task = AgentTask(title: "Retry Stale Durable", goal: "Initial request", workspace: workspace)
        task.status = .failed
        env.context.insert(workspace)
        env.context.insert(task)

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Stale queued follow-up",
            for: task,
            into: env.context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: env.context))
        let requestTerminalAt = Date()
        TaskTurnRequestStateMachine.transition(request, to: .failed, terminalReason: "runtime_not_started", at: requestTerminalAt)
        let originalRequestID = request.id
        let originalSourceEventID = request.sourceEventID

        // A later, non-durable run (e.g. an approved-plan or base-task
        // retry) fails AFTER the durable request terminalized, without
        // adding a newer `user.message` event — the exact scenario where
        // `latestRetryableTurnRequest` correctly rejects the stale durable
        // request as the retry candidate.
        let laterRun = TaskRun(task: task)
        laterRun.status = .failed
        laterRun.stopReason = "no_usable_result"
        laterRun.startedAt = requestTerminalAt.addingTimeInterval(1)
        laterRun.completedAt = requestTerminalAt.addingTimeInterval(2)
        env.context.insert(laterRun)
        try env.context.save()

        let continuation = env.coordinator.retryTask(task)
        await Task.yield()
        let newQueuedRequest = try #require(
            try TaskTurnRequestRepository.requests(for: task, in: env.context).last
        )
        env.queue.cancelTurnRequest(id: newQueuedRequest.id, workspace: workspace, modelContext: env.context)
        env.queue.cancelAll()
        await continuation?.value

        // The legacy fallback must not resurrect the stale durable message:
        // retry falls back to the original task seed, recorded via the
        // "Task re-queued for retry." wording — not "Latest follow-up
        // re-queued for retry.", which would mean it replayed the stale
        // "Stale queued follow-up" text instead. Asserted against the
        // durable `task.retried` event rather than `AppLogger.entries`
        // (a bounded, process-wide ring buffer that can evict this test's
        // entries under full-suite parallel load).
        let retriedEvent = try #require(task.events.first { $0.type == "task.retried" })
        #expect(retriedEvent.payload == "Task re-queued for retry.")
        #expect(task.status == .queued)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: env.context)
        #expect(requests.count == 2)
        let oldRequest = try #require(requests.first { $0.id == originalRequestID })
        let newRequest = try #require(requests.first { $0.id != originalRequestID })
        #expect(oldRequest.state == .failed)
        #expect(oldRequest.sourceEventID == originalSourceEventID)
        #expect(oldRequest.terminalAt == requestTerminalAt)
        #expect(newRequest.kind == .retry)
        #expect(newRequest.sequence == 2)
        let newSourceEvent = try #require(task.events.first { $0.id == newRequest.sourceEventID })
        let newSource = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(newSourceEvent))
        #expect(newSource.launchMode == .initial)
        #expect(newSource.message == nil)
    }

    @Test("Deleting a task cancels and removes its durable turn requests")
    func deleteTaskCancelsAndRemovesTurnRequests() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Delete Turn Cleanup", primaryPath: env.root)
        let task = AgentTask(title: "Delete Turn Cleanup", goal: "Initial request", workspace: workspace)
        task.status = .completed
        env.context.insert(workspace)
        env.context.insert(task)
        let taskID = task.id

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Queued follow-up",
            for: task,
            into: env.context
        ).successValue)
        try env.context.save()

        // A zero-size pool keeps the admission coroutine parked in its
        // waiting-for-worker poll, exactly where deletion must interrupt it.
        let admission = Task { @MainActor in
            await env.queue.continueSession(
                task: task,
                message: "Queued follow-up",
                existingMessageEventID: submission.eventID,
                turnRequestID: submission.requestID,
                modelContext: env.context
            )
        }
        await Task.yield()

        _ = env.coordinator.deleteTask(task)
        let started = await admission.value

        #expect(!started)
        let remaining = try env.context.fetch(FetchDescriptor<TaskTurnRequest>())
            .filter { $0.taskID == taskID }
        #expect(remaining.isEmpty)
    }

    @Test("Deleting a workspace cancels and removes its tasks' turn requests")
    func deleteWorkspaceRemovesTurnRequests() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Delete WS Cleanup", primaryPath: env.root)
        let task = AgentTask(title: "Delete WS Cleanup", goal: "Initial request", workspace: workspace)
        task.status = .completed
        env.context.insert(workspace)
        env.context.insert(task)
        let taskID = task.id

        _ = try #require(TaskTurnSubmissionService.submit(
            message: "Queued follow-up",
            for: task,
            into: env.context
        ).successValue)
        try env.context.save()

        // The workspace→task cascade cannot reach scalar turn-request rows;
        // deleteWorkspace must cancel and remove them per task first.
        _ = env.coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace])

        let remaining = try env.context.fetch(FetchDescriptor<TaskTurnRequest>())
            .filter { $0.taskID == taskID }
        #expect(remaining.isEmpty)
    }

    private static func fakeOpenCodeScript(argsFile: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "opencode fake 1.0"
          exit 0
        fi
        printf '%s\\n' "$@" > \(HeadlessChatScenarioTests.shQuote(argsFile.path))
        printf '%s\\n' '{"type":"text","sessionID":"retry-session","part":{"type":"text","text":"Retried latest follow-up."}}'
        printf '%s\\n' '{"type":"step_finish","sessionID":"retry-session","part":{"type":"step-finish","reason":"stop","tokens":{"total":4,"input":3,"output":1,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0}}'
        exit 0
        """
    }
}

private extension Result where Failure == TaskTurnSubmissionService.SubmissionError {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
