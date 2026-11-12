import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// A task whose only attempt was stopped before any provider started has done
/// nothing that could need verifying. When a finished task still holds its
/// workspace, the person's retry or new message must be able to receive the
/// same explicit workspace decision a first instruction can, or the task has
/// no way forward at all.
@Suite("Workspace continuation after an attempt that never launched", .serialized)
@MainActor
struct RuntimeWorkspaceContinuationUnlaunchedTests {
    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    /// A finished task whose provider ended but whose tool effects were never confirmed stopped.
    private func holder(_ h: HeadlessChatHarness) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Keep previous work", model: "test")
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.setOutput("Preserved answer")
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = .completed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished; record.inheritedToolUncertainty = true
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        try save(record, h); try h.context.save()
        return (task, record)
    }

    /// A task in the holder's workspace whose only run a provider reservation stopped before launch.
    private func blocked(_ h: HeadlessChatHarness, beside other: AgentTask, fault: String = "none") throws -> (AgentTask, TaskRun) {
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Saved instruction", model: "test")
        task.workspace = other.workspace
        task.status = .pendingUser
        let run = TaskRun(task: task)
        run.runtimeID = AgentRuntimeID.antigravityCLI.rawValue
        run.status = fault == "completedRun" ? .completed : .failed
        run.stopReason = RuntimeProviderResourceRegistry.Block.stopReason
        run.completedAt = Date()
        if fault == "spent" { run.tokensUsed = 10 }
        h.context.insert(run)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context)
        record.state = .notStarted
        record.providerLaunchCount = fault == "launched" ? 1 : 0
        record.providerProcess = nil
        record.stopProof = nil
        record.resourcesReleased = true
        if fault == "otherRun" { record.runID = UUID() }
        if fault == "cancelled" { record.cancellationRequested = true }
        // Uncertainty from this task's own earlier execution, not inherited from a neighbour.
        if fault == "ownEarlierExecution" { record.inheritedToolUncertainty = true; record.retainedExecutionHead = UUID() }
        try save(record, h); try h.context.save()
        return (task, run)
    }

    private func request(_ submission: ExecutionRequestSubmissionService.Submission, _ h: HeadlessChatHarness) throws -> TaskTurnRequest {
        try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
    }

    private func review(_ h: HeadlessChatHarness, task: AgentTask, request: TaskTurnRequest) throws -> RuntimeWorkspaceContinuationAuthorization {
        try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context,
            previous: try RuntimeTaskOwnerJournal.read(task: task, context: h.context))
    }

    @Test("The person's retry, or their new message, after a never-launched attempt can receive the workspace decision and start",
          arguments: ["retry", "followUp"])
    func continuesAfterDecision(kind: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try holder(h)
        let (b, _) = try blocked(h, beside: a)
        let saved = try kind == "retry"
            ? request(ExecutionRequestSubmissionService.submitRetry(message: "Saved instruction", continuation: true, for: b, into: h.context).get(), h)
            : request(ExecutionRequestSubmissionService.submitFollowUp(message: "Try again", for: b, into: h.context).get(), h)
        #expect(saved.kind == (kind == "retry" ? .retry : .followUp))
        let store = RuntimeExecutionOwner.store(in: h.context)
        let holderURL = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID).recordURL
        let bytes = try Data(contentsOf: holderURL)

        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: saved, task: b, runMode: "request", sandboxEnforcement: .off)
        // Without the person's decision the holder still fences the workspace.
        #expect(!queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        #expect(try RuntimeWorkspaceContinuation.admission(task: b, request: saved,
            previous: try RuntimeTaskOwnerJournal.read(task: b, context: h.context), context: h.context) == nil)

        let proposal = try review(h, task: b, request: saved)
        #expect(proposal.sources.map(\.receipt) == [original])
        try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: saved, context: h.context)
        queue.refreshResourceOwnership(in: h.context)
        #expect(queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context,
            maxRunSeconds: 60, userRequest: saved, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == saved.id)
        #expect(owner.record.inheritedToolUncertainty == true && owner.record.resourcesReleased == false)
        // The holder's own evidence is untouched: the decision certifies nothing about it.
        #expect(try Data(contentsOf: holderURL) == bytes)
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == original)
    }

    @Test("An attempt that launched, spent, was cancelled, carries its own earlier execution, or is not the saved one gets no decision",
          arguments: ["launched", "spent", "cancelled", "ownEarlierExecution", "otherRun", "completedRun"], ["retry", "followUp"])
    func attemptFences(fault: String, kind: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try holder(h)
        let (b, _) = try blocked(h, beside: a, fault: fault)
        let saved = try kind == "retry"
            ? request(ExecutionRequestSubmissionService.submitRetry(message: "Saved instruction", continuation: true, for: b, into: h.context).get(), h)
            : request(ExecutionRequestSubmissionService.submitFollowUp(message: "Try again", for: b, into: h.context).get(), h)
        #expect(throws: (any Error).self) { _ = try review(h, task: b, request: saved) }
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: saved) == nil)
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: a.id, taskOwnerID: a.persistentModelID) == original)
    }

    @Test("A request that already started, is bound to a run, or only claims to be a retry gets no decision",
          arguments: ["started", "boundRun", "sourceRun", "relabelled", "cancelledRequest"])
    func requestFences(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h)
        let (b, run) = try blocked(h, beside: a)
        // A relabelled request keeps its follow-up source, which is not a person's Retry.
        let saved = try fault == "relabelled"
            ? request(ExecutionRequestSubmissionService.submitFollowUp(message: "Try again", for: b, into: h.context).get(), h)
            : request(ExecutionRequestSubmissionService.submitRetry(message: "Saved instruction", continuation: true, for: b, into: h.context).get(), h)
        switch fault {
        case "started": saved.startedAt = Date()
        case "boundRun": saved.runID = run.id
        case "sourceRun": TaskHistoryRead.event(id: saved.sourceEventID, in: b)?.run = run
        case "relabelled": saved.kind = .retry
        default: _ = TaskTurnRequestStateMachine.transition(saved, to: .cancelled)
        }
        try h.context.save()
        #expect(throws: (any Error).self) { _ = try review(h, task: b, request: saved) }
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: saved) == nil)
    }

    @Test("A decision given to one never-launched retry does not carry to a later request of another kind")
    func decisionStaysWithItsRequest() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h)
        let (b, _) = try blocked(h, beside: a)
        let retry = try request(ExecutionRequestSubmissionService.submitRetry(message: "Saved instruction", continuation: true, for: b, into: h.context).get(), h)
        try RuntimeWorkspaceContinuation.authorize(try review(h, task: b, request: retry), task: b, request: retry, context: h.context)
        retry.kind = .scheduled
        try h.context.save()
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: retry) == nil)
    }
}
