import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Releasing a reservation must not strand the tasks that knew the holder:
/// the holder's own next message, and a task admitted earlier by a workspace
/// decision that named it.
@Suite("A released reservation does not strand its own task or its successors", .serialized)
@MainActor
struct RuntimeReservationReleaseOwnTaskTests {
    private static let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
    private var afterEverything: Date { Date().addingTimeInterval(3) }

    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    /// A holder whose turn ended with tools that could not be shown stopped.
    private func holder(_ h: HeadlessChatHarness, status: RunStatus, reason: TaskRunStopReason,
                        edit: (inout RuntimeExecutionOwnerRecord) -> Void = { _ in }) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-25)
        run.status = status; run.typedStopReason = reason; run.completedAt = Date().addingTimeInterval(-20)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run)
        task.status = status == .completed ? .completed : .failed
        try h.context.save()
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = status == .completed ? .finished : .unverified
        record.providerLaunchCount = 1
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task, runMode: "previous", sandboxEnforcement: .off)
        record.resourcesReleased = false
        edit(&record)
        try save(record, h); try h.context.save()
        return (task, record)
    }

    private func followUp(_ text: String, _ task: AgentTask, _ h: HeadlessChatHarness) throws -> TaskTurnRequest {
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: text, for: task, into: h.context).get()
        return try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
    }

    @Test("A task admitted by an earlier decision accepts its next message after its holder released")
    func successorKeepsWorking() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h, status: .completed, reason: .completed)
        let b = h.makeTask(runtime: .codexCLI, goal: "Saved initial instruction", model: "test")
        b.workspace = a.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: b, into: h.context).get()
        let first = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let proposal = try RuntimeWorkspaceContinuation.preview(task: b, request: first, context: h.context)
        try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: first, context: h.context)
        // B is admitted over the decision and its first turn ends, with tools
        // that could not be shown stopped, like any tool-using run.
        let run: TaskRun
        do {
            let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: first))
            run = TaskRun(task: b)
            run.startedAt = Date().addingTimeInterval(-10)
            run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date().addingTimeInterval(-5)
            run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            h.context.insert(run); b.status = .completed
            try owner.bind(run: run)
            owner.finish()
        }
        var turn = try #require(try RuntimeExecutionOwner.existing(task: b, context: h.context))
        #expect(turn.workspaceContinuationRequestID == first.id)
        turn.state = .finished; turn.providerProcess = Self.dead; turn.providerLaunchCount = 1
        turn.stopProof = .init(executionID: turn.executionID, process: Self.dead, reaped: true, processGroupEmpty: true,
            toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date().addingTimeInterval(-5))
        turn.settlementInProgress = false; turn.settlementLocalWorkStopped = true; turn.settlementToolsStopped = true
        turn.resourcesReleased = false
        try save(turn, h)
        first.state = .completed; first.runID = run.id
        try h.context.save()

        // The rule ends both reservations. B's saved decision still names A's earlier receipt.
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context)?.resourcesReleased == true)

        let second = try followUp("Next message", b, h)
        let previous = try RuntimeExecutionOwner.existing(task: b, context: h.context)
        // No holder is left to except, so this is ordinary admission and not a refusal.
        #expect(try RuntimeWorkspaceContinuation.admission(task: b, request: second, previous: previous, context: h.context) == nil)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: second))
        owner.finish()
    }

    @Test("The holder's own next message starts after a release, whatever its last turn left behind",
          arguments: ["timeoutGroupNotEmpty", "staleSettlementBarrier", "cancelled"])
    func ownNextMessage(shape: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, saved) = try holder(h, status: shape == "cancelled" ? .cancelled : .failed,
            reason: shape == "cancelled" ? .cancelled : .providerRunWallClockExceeded) { record in
            switch shape {
            case "timeoutGroupNotEmpty":
                let old = record.stopProof!
                record.stopProof = .init(executionID: old.executionID, process: old.process, reaped: true, processGroupEmpty: false,
                    toolsStopped: false, remoteWorkExcluded: true, capturedAt: old.capturedAt)
            case "staleSettlementBarrier": record.settlementInProgress = true; record.settlementLocalWorkStopped = false
            default: record.cancellationRequested = true
            }
            // Something the earlier turn held that the next request does not name.
            let earlier = TaskResourceLockClaim(taskID: record.taskID, resourceKey: "/private/tmp/astra-earlier-folder",
                accessMode: .write, runMode: "previous")
            record.resourceClaims?.append(earlier)
        }
        let request = try followUp("Carry on", task, h)
        // Held: neither a retry nor the person's new message can start.
        #expect(!RuntimeCompletedUserTurnContinuation.permits(saved, task: task, request: request, context: h.context))
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(released.resourcesReleased == true && !released.canReplace)
        #expect(RuntimeCompletedUserTurnContinuation.permits(released, task: task, request: request, context: h.context))
        // Retry still needs the full proof.
        #expect(RuntimeExecutionOwner.retryDecision(task: task, context: h.context) == .blocked)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
        defer { owner.finish() }
        // The new turn claims what it asked for; nothing is carried over from the released receipt.
        #expect(owner.record.ownerID == saved.ownerID && owner.record.retainedExecutionHead == saved.executionID)
        #expect(owner.record.resourceClaims?.isEmpty == false)
        #expect(owner.record.resourceClaims?.contains { $0.resourceKey == "/private/tmp/astra-earlier-folder" } == false)
    }

    @Test("After that next turn ends cleanly the task does not hold the folder again in the same boot")
    func releasedLineageIsNotAskedAgain() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, _) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let request = try followUp("Carry on", task, h)
        do {
            let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
            let run = TaskRun(task: task)
            run.startedAt = Date(); run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
            run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            h.context.insert(run); task.status = .completed
            try owner.bind(run: run)
            owner.finish()
        }
        try h.context.save()
        // The new turn launched nothing. Its journal was written in this boot,
        // which must not send the already released earlier execution back to "unknown".
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: Date().addingTimeInterval(-600))
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
    }

    @Test("Check again on a timed-out run that was already released has nothing left to do")
    func timeoutCheckAfterRelease() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, _) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded) { record in
            let old = record.stopProof!
            record.stopProof = .init(executionID: old.executionID, process: old.process, reaped: true, processGroupEmpty: false,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: old.capturedAt)
        }
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        let runID = try #require(released.runID)
        try RuntimeTimeoutRecoveryCheck.check(task: task, runID: runID, context: h.context)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == released)
    }
}
