import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Cleanup proof is shared by every admission path", .serialized)
@MainActor
struct RuntimeCleanupAuthorizationTests {
    @Test("Uncertain non-user stops retain resources across providers while unrelated work continues", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func unverifiedExit(runtime: AgentRuntimeID) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: runtime, goal: "Original", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task)
        h.context.insert(run)
        try owner.bind(run: run)
        let shared = AgentRuntimeSharedStateKey(runtime: runtime, identifier: h.workspaceURL.path)
        try owner.bindProviderSharedState(shared)
        try owner.prepareLaunch()
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: ["-c", "exit 0"],
            currentDirectory: h.workspaceURL.path, environment: [:])
        try process.run()
        try owner.launched(process)
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        defer { process.terminate() }
        #expect(!process.isRunning)
        owner.stopped(proof: process.stopProof(executionID: owner.record.executionID,
            toolsStopped: false, remoteWorkExcluded: true), turns: 1, tokens: 120, seconds: 1)
        // Neither an apparent successful result nor the absence of a manual
        // cancellation request may authorize release after uncertain cleanup.
        task.status = .completed
        run.status = .completed
        #expect(owner.record.cancellationRequested != true)
        #expect(!owner.releaseProviderSharedState())
        owner.finish()
        #expect(!owner.persistedResourceRelease)
        #expect(owner.record.state == .finished)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context)?.contains("cannot confirm") == true)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: nil, task: task, runMode: "continue")
        #expect(!queue.canAcquireResourceLocks(claims))
        let blocker = queue.resourceBlockerSummary(claims, modelContext: h.context)
        #expect(blocker.contains("cleanup is not yet confirmed"))
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Continue", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        TaskTurnRequestStateMachine.transition(request, to: .waitingForResource,
            blockingTaskID: task.id, blockerSummary: blocker)
        let activity = TaskActivityPresentation.resolve(taskID: task.id, taskStatus: task.status, requests: [request.snapshot])
        #expect(activity.kind == .waitingForResource)
        #expect(activity.cancellableQueuedRequest?.id == request.id)
        let cancel = TaskDecisionDockAction(kind: .cancelTurnRequest, title: "Cancel request", systemImage: "xmark.circle",
            payload: request.id.uuidString, help: "Cancel this saved message before it runs.")
        let waiting = TaskDecisionDockPresentation(id: "waiting", icon: "lock.clock", tone: .attention,
            title: try #require(activity.dockTitle), summary: try #require(activity.dockSummary), metrics: [], details: [],
            primaryAction: nil, secondaryActions: [cancel], overflowActions: [], prefersExpandedDetails: false)
        let presentation = RuntimeRecoveryPresentation.waitingDock(waiting,
            blockedMessage: RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context))
        #expect(presentation.title == "Recovery blocked")
        #expect(presentation.summary.contains("cannot confirm"))
        #expect(presentation.details.contains { $0.title == "Why this request waits" })
        #expect(presentation.secondaryActions == [cancel])
        #expect(request.runID == nil && request.state == .waitingForResource)
        // The disconnected run may have left an unanswered permission in
        // durable state. It cannot replace the saved message's Cancel request
        // action, nor can displaying either card authorize another execution.
        let permissionPayload = PermissionBroker.approvalPayloadString(providerID: runtime,
            request: .shell(command: "echo synthetic", toolName: "Bash"),
            reason: "The previous execution requested permission before it disconnected.",
            grants: [.shellCommand(executable: "echo", pattern: "*")], requestID: "disconnected-permission")
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: permissionPayload, task: task)
        task.status = .pendingUser
        try h.context.save()
        let permission = TaskRuntimePermissionState.build(task: task)
        #expect(permission.hasOpenApprovalRequest)
        #expect(try RuntimeExecutionOwner.inspection(task: task, context: h.context)?.canReconnect == false)
        let blockedMessage = try #require(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context))
        let disconnectedPresentation = try #require(RuntimeRecoveryPresentation.queuedRequestDock(waiting,
            hasOpenApprovalRequest: permission.hasOpenApprovalRequest, blockedMessage: blockedMessage))
        #expect(disconnectedPresentation.title == "Recovery blocked")
        #expect(disconnectedPresentation.summary.contains(blockedMessage))
        #expect(disconnectedPresentation.secondaryActions == [cancel])
        #expect(disconnectedPresentation.primaryAction == nil)
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: task) == permissionPayload)
        #expect(request.runID == nil && request.state == .waitingForResource)
        #expect(throws: (any Error).self) {
            try RuntimeProviderResourceRegistry.assertAvailable(shared, ownerID: nil,
                in: [RuntimeExecutionOwner.store(in: h.context).root])
        }
        let otherRuntime: AgentRuntimeID = runtime == .codexCLI ? .claudeCode : .codexCLI
        let contender = h.makeTask(runtime: otherRuntime, goal: "Contender", model: "test")
        #expect(RuntimeExecutionOwner.acquire(task: contender, context: h.context, maxRunSeconds: 60) == nil)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
        let persisted = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(persisted.executionID == owner.record.executionID)
        #expect(persisted.limits == owner.record.limits)
        let separate = h.workspaceURL.deletingLastPathComponent().appendingPathComponent("independent-\(UUID())")
        try FileManager.default.createDirectory(at: separate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: separate) }
        let workspace = Workspace(name: "Independent", primaryPath: separate.path)
        h.context.insert(workspace)
        let independent = AgentTask(title: "Independent", goal: "Synthetic", workspace: workspace, runtime: otherRuntime)
        h.context.insert(independent)
        let independentOwner = try #require(RuntimeExecutionOwner.acquire(task: independent, context: h.context, maxRunSeconds: 60))
        independentOwner.finish()
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: independent, context: h.context) == nil)
    }

    @Test("Missing receipts are explained using the same admission rule", arguments: [TaskStatus.completed, .pendingUser, .queued])
    func missingReceiptPresentation(status: TaskStatus) throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .codexCLI, goal: "Legacy task", model: "test")
        task.status = status
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
        let run = TaskRun(task: task)
        run.status = .completed
        h.context.insert(run)
        let eventCount = task.events.count
        let message = try #require(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context))
        #expect(message.contains("receipt is missing"))
        #expect(task.status == status && task.events.count == eventCount)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == nil)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else {
            Issue.record("Presentation and Retry disagreed about the missing receipt")
        }
    }

    @Test("A historical resource release cannot hide unverified task recovery")
    func historicalReleaseStillExplainsBlockedRetry() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy release", model: "test")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        h.context.insert(run)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished
        record.resourcesReleased = true
        record.providerSharedStateReleased = true
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(record) }
        #expect(!RuntimeResourceOwnership.retainsResources(record))
        #expect(!record.canReplace)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context)?.contains("cannot confirm") == true)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == record)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else {
            Issue.record("Historical resource release authorized an unverified retry")
        }
    }
}
