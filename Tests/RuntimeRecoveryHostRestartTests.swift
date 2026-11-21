import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// No local process outlives a restart of this Mac. A finished owner whose
/// every execution ended before the boot, on the host and with remote work
/// excluded, releases its reservation without a person deciding anything.
@Suite("A restart releases what ended before it", .serialized)
@MainActor
struct RuntimeRecoveryHostRestartTests {
    private static let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)

    private func endedRun(_ task: AgentTask, _ h: HeadlessChatHarness, ago: TimeInterval = 20) -> TaskRun {
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-ago - 5)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date().addingTimeInterval(-ago)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run)
        return run
    }

    /// A finished execution that used tools: reaped, group empty, no remote
    /// route, but its transcript could not show the tools stopped.
    private func record(_ task: AgentTask, run: TaskRun, owner: UUID = UUID(), ended: TimeInterval = 20) -> RuntimeExecutionOwnerRecord {
        let execution = UUID()
        var value = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: owner, executionID: execution, runID: run.id,
            appProcess: Self.dead, providerProcess: Self.dead, runtime: task.resolvedRuntimeID.rawValue, sessionID: nil,
            state: .finished, limits: .init(tokenCeiling: 1_000, turnsRemaining: 4, secondsRemaining: 60, tokensSpent: 10, costSpent: 0),
            stopProof: .init(executionID: execution, process: Self.dead, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date().addingTimeInterval(-ended)),
            updatedAt: Date())
        value.taskOwnerID = task.persistentModelID
        value.inheritedToolUncertainty = true
        value.settlementInProgress = false; value.settlementLocalWorkStopped = true; value.settlementToolsStopped = true
        value.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task, runMode: "previous", sandboxEnforcement: .off)
        value.resourcesReleased = false
        return value
    }

    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    private func finishedTask(_ h: HeadlessChatHarness) throws -> (AgentTask, TaskRun) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        task.status = .completed
        let run = endedRun(task, h)
        try h.context.save()
        return (task, run)
    }

    /// The journal's own change time must predate the boot too, so the boot
    /// used here is a moment after everything above was written.
    private var afterEverything: Date { Date().addingTimeInterval(3) }

    @Test("An owner that ended before the restart is released; the next task starts with no decision")
    func releasesAfterRestart() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try finishedTask(h)
        let original = record(task, run: run)
        try save(original, h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        #expect(try !RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)

        let boot = afterEverything
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot)
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(released.resourcesReleased == true && released.canReplace && released.inheritedToolUncertainty == false)
        #expect(released.stopProof?.toolsStopped == true)
        #expect(released.stopProof?.hostRestart?.bootedAt == boot && released.stopProof?.hostRestart?.inheritedToolUncertainty == true)
        #expect(released.hostNoToolReconciliationOriginalProof == original.stopProof)
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
        #expect(TaskHistoryRead.events(for: task, ofTypes: [TaskEventTypes.System.runtimeExecutionOwnership.rawValue]).count == 1)

        // Asking again changes nothing.
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == released)

        let next = h.makeTask(runtime: .codexCLI, goal: "A new instruction", model: "test")
        next.workspace = task.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: next, context: h.context, maxRunSeconds: 60, userRequest: request))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == nil && owner.record.inheritedToolUncertainty == false)
    }

    @Test("A PID that another user's process holds now is a different process, not an unknown one")
    func reusedPID() throws {
        // launchd belongs to root: this user can neither inspect nor signal it.
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, 1]
        try #require(sysctl(&name, 4, &info, &size, nil, 0) == 0 && getuid() != 0)
        let launchd = RuntimeProcessIdentity(pid: 1, startedSeconds: UInt64(info.kp_proc.p_un.__p_starttime.tv_sec),
            startedMicroseconds: UInt64(info.kp_proc.p_un.__p_starttime.tv_usec))
        #expect(RuntimeProcessIdentity.read(1) == nil)
        #expect(launchd.presence == .present)
        #expect(RuntimeProcessIdentity(pid: 1, startedSeconds: launchd.startedSeconds - 1, startedMicroseconds: 0).presence == .absent)
        #expect(Self.dead.presence == .absent)
    }

    @Test("An earlier attempt labelled not started does not hold the owner back once a restart has passed",
          arguments: ["unspent", "spentAndCancelled", "toolsNotSettled", "stillSettling"])
    func unlaunchedHistory(shape: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        task.status = .completed
        let failedRun = endedRun(task, h, ago: 60), lastRun = endedRun(task, h, ago: 20)
        failedRun.status = .failed; failedRun.typedStopReason = .providerRunWallClockExceeded
        if shape == "spentAndCancelled" { failedRun.tokensUsed = 5; failedRun.inputTokens = 5 }
        try h.context.save()
        var last = record(task, run: lastRun)
        var attempt = RuntimeExecutionOwnerRecord(taskID: task.id, taskOwnerID: task.persistentModelID, ownerID: last.ownerID,
            executionID: UUID(), runID: failedRun.id, appProcess: Self.dead, providerProcess: nil, runtime: last.runtime, sessionID: nil,
            state: .notStarted, limits: last.limits, stopProof: nil, resourceClaims: last.resourceClaims, updatedAt: Date())
        switch shape {
        case "spentAndCancelled":
            attempt.cancellationRequested = true
            attempt.settlementInProgress = false; attempt.settlementLocalWorkStopped = true; attempt.settlementToolsStopped = true
        case "toolsNotSettled": attempt.settlementToolsStopped = false
        case "stillSettling": attempt.settlementInProgress = true
        default: break
        }
        last.retainedExecutionHead = attempt.executionID
        let store = RuntimeExecutionOwner.store(in: h.context)
        try save(attempt, h)
        try store.retain(attempt)
        try save(last, h)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        // A settlement barrier the attempt left open is answered by the restart
        // as well: no check ASTRA started outlives it. Only the stop proof,
        // which Retry reads, still needs that barrier closed.
        let current = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(current.resourcesReleased == true && current.reservationRelease?.basis == .hostRestart)
        #expect(current.canReplace == (shape == "unspent" || shape == "spentAndCancelled"))
    }

    @Test("Every earlier execution of the owner is asked too; only one a restart cannot answer holds",
          arguments: ["clean", "remote", "cancelled", "container"])
    func history(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        task.status = .completed
        let firstRun = endedRun(task, h, ago: 60), lastRun = endedRun(task, h, ago: 20)
        try h.context.save()
        var first = record(task, run: firstRun, ended: 60)
        if fault == "remote", let proof = first.stopProof {
            first.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: false, capturedAt: proof.capturedAt)
        }
        if fault == "cancelled" { first.cancellationRequested = true }
        if fault == "container" {
            var environment = WorkspaceExecutionEnvironment.host; environment.kind = .dockerImage
            firstRun.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
            try h.context.save()
        }
        var last = record(task, run: lastRun, owner: first.ownerID)
        last.retainedExecutionHead = first.executionID
        let store = RuntimeExecutionOwner.store(in: h.context)
        try save(first, h)
        try store.retain(first)
        try save(last, h)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let current = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        // A cancelled earlier execution, and one whose tools ran with an SSH
        // route open, are as gone as any other after a restart. The reservation
        // ends; the stop proof is upgraded only for the clean one. A container
        // keeps its own processes across the host's exit record.
        #expect((current.resourcesReleased == true) == (fault != "container"))
        #expect(current.canReplace == (fault == "clean"))
        if fault == "container" { #expect(current == last) }
    }

    /// What a restart does answer (a failed or cancelled turn, an open
    /// settlement barrier, an unrecorded exit, a registration with no job, a
    /// tool run with an SSH route open) is in `RuntimeReservationReleaseTests`.
    @Test("Anything a restart cannot answer keeps the reservation", arguments: [
        "noBootTime", "bootBeforeEnd", "journalAfterBoot",
        "running", "noHostSnapshot", "sessionPending", "sshPending", "appAlive", "otherRuntime"])
    func gates(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try finishedTask(h)
        var saved = record(task, run: run)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var boot: Date? = afterEverything
        switch fault {
        case "noBootTime": boot = nil
        case "bootBeforeEnd": boot = Date().addingTimeInterval(-600)
        case "journalAfterBoot": boot = Date().addingTimeInterval(-10)   // after the run and the proof, before the journal was written
        case "running": let other = TaskRun(task: task); other.startedAt = Date().addingTimeInterval(-100); other.status = .running; h.context.insert(other)
        case "noHostSnapshot": run.executionEnvironmentSnapshotJSON = nil
        case "sessionPending": saved.sessionVerificationPending = true
        case "sshPending": saved.pendingSSHJobSetDigest = "digest"
        case "appAlive":
            saved = RuntimeExecutionOwnerRecord(taskID: saved.taskID, taskOwnerID: saved.taskOwnerID, ownerID: saved.ownerID,
                executionID: saved.executionID, runID: saved.runID,
                appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
                providerProcess: saved.providerProcess, runtime: saved.runtime, sessionID: nil, state: .finished, limits: saved.limits,
                stopProof: saved.stopProof, inheritedToolUncertainty: true, settlementInProgress: false,
                settlementLocalWorkStopped: true, settlementToolsStopped: true, resourceClaims: saved.resourceClaims,
                resourcesReleased: false, updatedAt: saved.updatedAt)
        default: saved.runtime = "another_runtime"
        }
        try save(saved, h); try h.context.save()
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == saved)
        #expect(try !RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
    }

    @Test("Receipts written before this evidence existed decode and encode unchanged")
    func olderReceipts() throws {
        let proof = RuntimeExecutionStopProof(executionID: UUID(), process: Self.dead, reaped: true, processGroupEmpty: true,
            toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(proof)
        #expect(!String(decoding: data, as: UTF8.self).contains("hostRestart"))
        #expect(try JSONDecoder().decode(RuntimeExecutionStopProof.self, from: data) == proof)
        let boot = Date(timeIntervalSince1970: 1_700_000_100)
        let observation = RuntimeHostRestartObservation(bootedAt: boot, observedAt: boot, inheritedToolUncertainty: nil)
        #expect(proof.restarted(observation).toolsStopped && proof.restarted(observation).hostRestart == observation)
        // A proof captured after the boot, or one that cannot exclude remote work, is not answered.
        #expect(proof.restarted(.init(bootedAt: proof.capturedAt, observedAt: boot, inheritedToolUncertainty: nil)) == proof)
        let remote = RuntimeExecutionStopProof(executionID: proof.executionID, process: Self.dead, reaped: true, processGroupEmpty: true,
            toolsStopped: false, remoteWorkExcluded: false, capturedAt: proof.capturedAt)
        #expect(remote.restarted(observation) == remote)
    }
}
