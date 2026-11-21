import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// A task whose last turn failed keeps its workspace reserved exactly like a
/// completed one: the provider is reaped, its group is empty, settlement is
/// done, and only its tool effects are unverified. A workspace decision an
/// earlier build saved in another task accepts that, and nothing about the
/// process evidence is relaxed for it. No such decision is written any more:
/// what a person can start past today is in `RuntimeWorkspaceReviewTests`.
@Suite("A saved workspace decision over a holder whose last turn failed", .serialized)
@MainActor
struct RuntimeWorkspaceContinuationFailedHolderTests {
    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    private func proof(_ record: RuntimeExecutionOwnerRecord, process: RuntimeProcessIdentity? = nil, reaped: Bool = true,
                       groupEmpty: Bool = true, observedEmptyAt: Date? = nil) throws -> RuntimeExecutionStopProof {
        let original = try #require(record.stopProof)
        return .init(executionID: original.executionID, process: process ?? original.process, reaped: reaped,
            processGroupEmpty: groupEmpty, toolsStopped: false, remoteWorkExcluded: true, capturedAt: original.capturedAt,
            groupObservedEmptyAt: observedEmptyAt)
    }

    /// The shape found in production: ASTRA stopped the provider mid-command,
    /// the run failed, and the person then approved the partial result, so the
    /// task reads completed while its receipt stays unverified.
    private func holder(_ h: HeadlessChatHarness, status: RunStatus = .failed,
                        reason: TaskRunStopReason = .capabilitySessionExpired,
                        change: (inout RuntimeExecutionOwnerRecord, TaskRun) throws -> Void = { _, _ in }) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .codexCLI, goal: "Earlier work that failed", model: "test")
        let run = TaskRun(task: task)
        run.status = status; run.typedStopReason = reason; run.completedAt = Date()
        run.setOutput("Partial work")
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = .completed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.inheritedToolUncertainty = true
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        try change(&record, run)
        try save(record, h); try h.context.save()
        return (task, record)
    }

    private func next(_ h: HeadlessChatHarness, after task: AgentTask) throws -> (AgentTask, TaskTurnRequest) {
        let next = h.makeTask(runtime: .claudeCode, goal: "A new instruction", model: "test")
        next.workspace = task.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        return (next, try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context)))
    }

    @Test("A decision saved over a holder whose last turn failed, timed out or ran out of budget still admits its request",
          arguments: ["failed", "timeout", "budgetExceeded"])
    func continuesOverEndedHolder(outcome: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (status, reason): (RunStatus, TaskRunStopReason) = outcome == "timeout" ? (.timeout, .providerRunWallClockExceeded)
            : outcome == "budgetExceeded" ? (.budgetExceeded, .maxBudgetReached) : (.failed, .capabilitySessionExpired)
        let (a, original) = try holder(h, status: status, reason: reason)
        #expect(!RuntimeCompletedUserTurnContinuation.hasCompletedTurn(original, task: a, context: h.context))
        let (b, request) = try next(h, after: a)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let holderURL = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID).recordURL
        let bytes = try Data(contentsOf: holderURL)

        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: b, runMode: "initial", sandboxEnforcement: .off)
        // Without the person's decision the failed holder still fences the workspace.
        #expect(!queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        #expect(try RuntimeWorkspaceContinuation.admission(task: b, request: request, previous: nil, context: h.context) == nil)

        let proposal = try RuntimeWorkspaceLegacyDecision.save(task: b, request: request, context: h.context)
        #expect(proposal.sources.map(\.receipt) == [original])
        queue.refreshResourceOwnership(in: h.context)
        #expect(queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        do {
            let admission = try #require(try RuntimeWorkspaceContinuation.admission(task: b, request: request, previous: nil, context: h.context))
            #expect(!admission.excludedClaims.isEmpty && admission.excludedClaims.allSatisfy { $0.taskID == a.id })
        }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context,
            maxRunSeconds: 60, userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == request.id)
        #expect(owner.record.inheritedToolUncertainty == true && owner.record.resourcesReleased == false)
        // The decision certifies nothing about the holder: its evidence, its
        // failed run and its reservation against everyone else are untouched.
        #expect(try Data(contentsOf: holderURL) == bytes)
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == original)
        #expect(a.runs.first?.status == status && a.runs.first?.typedStopReason == reason)
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).contains { $0.taskID == a.id })
        let (c, other) = try next(h, after: a)
        #expect(RuntimeExecutionOwner.acquire(task: c, context: h.context, maxRunSeconds: 60, userRequest: other) == nil)
    }

    @Test("A failed holder that may still be running, is unsettled, or was cancelled is not covered by a saved decision", arguments:
        ["liveProvider", "unreaped", "groupNotEmpty", "laterObservationOnly", "running", "newerRun", "settling",
         "settlementTools", "settlementLocalWork", "cancelledAttempt", "noEnvironment", "noEndTime"])
    func unsettledHolderRefuses(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let timedOut = fault == "laterObservationOnly"
        let (a, receipt) = try holder(h, status: timedOut ? .timeout : .failed,
            reason: timedOut ? .providerRunWallClockExceeded : .capabilitySessionExpired) { record, run in
            switch fault {
            case "liveProvider":
                let live = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
                record.providerProcess = live
                record.stopProof = try proof(record, process: live)
            case "unreaped": record.stopProof = try proof(record, reaped: false)
            case "groupNotEmpty": record.stopProof = try proof(record, groupEmpty: false)
            // Enough for the owner's own next message, never for another task.
            case "laterObservationOnly": record.stopProof = try proof(record, groupEmpty: false, observedEmptyAt: Date())
            case "running": run.status = .running
            case "settling": record.settlementInProgress = true
            case "settlementTools": record.settlementToolsStopped = false
            case "settlementLocalWork": record.settlementLocalWorkStopped = false
            case "noEnvironment": run.executionEnvironmentSnapshotJSON = nil
            case "noEndTime": run.completedAt = nil
            default: break
            }
        }
        if fault == "newerRun" {
            let later = TaskRun(task: a)
            later.startedAt = Date().addingTimeInterval(60); later.status = .running
            h.context.insert(later); try h.context.save()
        }
        if fault == "cancelledAttempt" {
            // A turn the person stopped, with its cancellation durably joined.
            let run = try #require(a.runs.first)
            let stopped = try ExecutionRequestSubmissionService.submitFollowUp(message: "Stopped", for: a, into: h.context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: stopped.requestID, in: h.context))
            request.runID = run.id
            _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled)
            run.status = .cancelled; run.typedStopReason = .cancelled
            var cancelled = receipt; cancelled.cancellationRequested = true; cancelled.continuingUserRequestID = request.id
            try save(cancelled, h); try h.context.save()
        }
        if timedOut || fault == "cancelledAttempt" {
            // The owner's own follow-up accepts this; the other task's decision must not.
            let current = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
            try #require(RuntimeCompletedUserTurnContinuation.hasSettledTurn(current, task: a, context: h.context))
        }
        let (b, request) = try next(h, after: a)
        try RuntimeWorkspaceLegacyDecision.save(task: b, request: request, context: h.context)
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    @Test("A failed holder that changes after the decision was saved is no longer covered by it",
          arguments: ["running", "liveLease", "changed"])
    func decisionIsRevalidated(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try holder(h)
        let (b, request) = try next(h, after: a)
        try RuntimeWorkspaceLegacyDecision.save(task: b, request: request, context: h.context)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var live: RuntimeExecutionOwnerStore.Lease?
        defer { withExtendedLifetime(live) {} }
        switch fault {
        case "running": a.runs.first?.status = .running; try h.context.save()
        case "liveLease": live = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
        default:
            var changed = original; changed.limits.tokensSpent += 1
            try save(changed, h)
        }
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: b, runMode: "initial", sandboxEnforcement: .off)
        #expect(!queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }
}
