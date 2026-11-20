import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

/// A reservation ends when nothing its owner started can still act. The rule
/// reads present facts and never the outcome of the work.
@Suite("A reservation ends when nothing of its owner can still act", .serialized)
@MainActor
struct RuntimeReservationReleaseTests {
    private static let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
    private static var alive: RuntimeProcessIdentity {
        get throws { try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)) }
    }

    private func run(_ task: AgentTask, _ h: HeadlessChatHarness, status: RunStatus = .completed,
                     reason: TaskRunStopReason = .completed) -> TaskRun {
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-25)
        run.status = status; run.typedStopReason = reason; run.completedAt = Date().addingTimeInterval(-20)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run)
        return run
    }

    /// An execution that used tools: reaped, group empty, no SSH route, and a
    /// transcript that could not show the tools stopped.
    private func record(_ task: AgentTask, run: TaskRun, owner: UUID = UUID(),
                        state: RuntimeExecutionOwnerRecord.State = .finished) -> RuntimeExecutionOwnerRecord {
        let execution = UUID()
        var value = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: owner, executionID: execution, runID: run.id,
            appProcess: Self.dead, providerProcess: Self.dead, runtime: task.resolvedRuntimeID.rawValue, sessionID: nil,
            state: state, limits: .init(tokenCeiling: 1_000, turnsRemaining: 4, secondsRemaining: 60, tokensSpent: 10, costSpent: 0),
            stopProof: .init(executionID: execution, process: Self.dead, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date().addingTimeInterval(-20)),
            updatedAt: Date())
        value.taskOwnerID = task.persistentModelID
        value.providerLaunchCount = 1
        value.settlementInProgress = false; value.settlementLocalWorkStopped = true; value.settlementToolsStopped = true
        value.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task, runMode: "previous", sandboxEnforcement: .off)
        value.resourcesReleased = false
        return value
    }

    private func proof(_ record: inout RuntimeExecutionOwnerRecord, reaped: Bool = true, groupEmpty: Bool = true,
                       toolsStopped: Bool = false, remoteExcluded: Bool = true, managed: Bool? = nil,
                       survivors: RuntimeLocalSurvivorObservation? = nil) {
        let old = record.stopProof!
        var value = RuntimeExecutionStopProof(executionID: old.executionID, process: old.process, reaped: reaped,
            processGroupEmpty: groupEmpty, toolsStopped: toolsStopped, remoteWorkExcluded: remoteExcluded,
            capturedAt: old.capturedAt, managedSSHOnly: managed)
        value.localSurvivors = survivors
        record.stopProof = value
    }

    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    private func holder(_ h: HeadlessChatHarness, status: RunStatus = .completed,
                        reason: TaskRunStopReason = .completed) throws -> (AgentTask, TaskRun) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        task.status = status == .completed ? .completed : .failed
        let run = run(task, h, status: status, reason: reason)
        try h.context.save()
        return (task, run)
    }

    private func observation(_ record: RuntimeExecutionOwnerRecord, survivors: [RuntimeLocalSurvivorObservation.Survivor]) -> RuntimeLocalSurvivorObservation {
        .init(launch: .init(scope: UUID().uuidString, root: "/tmp", provider: record.providerProcess!, ended: record.stopProof!.capturedAt),
              observedAt: record.stopProof!.capturedAt, complete: true, survivors: survivors)
    }

    /// The journal's own change time must predate the boot, so the boot used
    /// here is a moment after everything was written.
    private var afterEverything: Date { Date().addingTimeInterval(3) }

    private func verdict(_ record: RuntimeExecutionOwnerRecord, _ task: AgentTask, _ h: HeadlessChatHarness, boot: Date?,
                         now: [RuntimeLocalSurvivorObservation.Survivor]? = []) throws -> RuntimeReservationRelease.Verdict {
        let store = RuntimeExecutionOwner.store(in: h.context)
        let lease = try store.acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        return RuntimeReservationRelease.verdict(record, task: task, journal: lease.recordURL, store: store,
            context: h.context, bootedAt: boot) { launch in
                .init(launch: launch, observedAt: Date(), complete: now != nil, survivors: now ?? [])
            }
    }

    @Test("The outcome of the work never decides: every ended turn that predates the boot is released",
          arguments: [RunStatus.completed, .failed, .timeout, .budgetExceeded, .cancelled],
                     [RuntimeExecutionOwnerRecord.State.finished, .stopped, .unverified])
    func outcomeAndStateAreNotRead(status: RunStatus, state: RuntimeExecutionOwnerRecord.State) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let reason: TaskRunStopReason = status == .completed ? .completed : status == .cancelled ? .cancelled : .providerRunWallClockExceeded
        let (task, run) = try holder(h, status: status, reason: reason)
        var saved = record(task, run: run, state: state)
        saved.inheritedToolUncertainty = true
        if status == .cancelled { saved.cancellationRequested = true }
        try save(saved, h)
        #expect(try verdict(saved, task, h, boot: afterEverything) == .release(.hostRestart))
        // In the same boot the transcript could not show the tools stopped and nothing else can answer.
        #expect(try verdict(saved, task, h, boot: Date().addingTimeInterval(-600)) == .held([.lostRun]))
    }

    @Test("Each fact holds the reservation alone and is named", arguments: [
        "running", "sessionPending", "providerAlive", "container", "noPlacement", "otherRuntime",
        "settling", "settlementTools", "unreaped", "groupNotEmpty", "survivorAlive", "newSurvivor",
        "tableUnreadable", "noBootTime", "journalAfterBoot", "supervisorAlive"])
    func eachFactHolds(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h)
        var saved = record(task, run: run)
        var boot: Date? = afterEverything
        var now: [RuntimeLocalSurvivorObservation.Survivor]? = []
        let mine = RuntimeLocalSurvivorObservation.Survivor(process: try Self.alive, name: "node")
        let gone = RuntimeLocalSurvivorObservation.Survivor(process: .init(pid: Int32.max - 1, startedSeconds: 1, startedMicroseconds: 1), name: "node")
        let expected: [RuntimeReservationRelease.Blocker]
        switch fault {
        case "running":
            let other = TaskRun(task: task); other.startedAt = Date().addingTimeInterval(-100); other.status = .running; h.context.insert(other)
            expected = [.taskWorking]
        case "sessionPending": saved.sessionVerificationPending = true; expected = [.sessionUnverified]
        case "providerAlive":
            saved.providerProcess = try Self.alive
            saved.stopProof = .init(executionID: saved.executionID, process: try Self.alive, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date().addingTimeInterval(-20))
            expected = [.providerAlive(pid: try Self.alive.pid)]
        case "container":
            var environment = WorkspaceExecutionEnvironment.host; environment.kind = .dockerImage
            run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
            expected = [.container]
        case "noPlacement": run.executionEnvironmentSnapshotJSON = nil; expected = [.placementUnrecorded]
        case "otherRuntime": saved.runtime = "another_runtime"; expected = [.placementUnrecorded]
        // The three below are answered by a restart, so they are asked in the same boot.
        case "settling": saved.settlementInProgress = true; boot = Date().addingTimeInterval(-600); proof(&saved, toolsStopped: true); expected = [.settlementUnconfirmed]
        case "settlementTools": saved.settlementToolsStopped = false; boot = Date().addingTimeInterval(-600); proof(&saved, toolsStopped: true); expected = [.settlementUnconfirmed]
        case "unreaped": proof(&saved, reaped: false, toolsStopped: true); boot = Date().addingTimeInterval(-600); expected = [.lostRun]
        case "groupNotEmpty": proof(&saved, groupEmpty: false, toolsStopped: true); boot = Date().addingTimeInterval(-600); expected = [.lostRun]
        case "survivorAlive": proof(&saved, survivors: observation(saved, survivors: [mine])); boot = nil; expected = [.survivors([mine])]
        case "newSurvivor": proof(&saved, survivors: observation(saved, survivors: [gone])); boot = nil; now = [mine]; expected = [.survivors([mine])]
        case "tableUnreadable": proof(&saved, survivors: observation(saved, survivors: [gone])); boot = nil; now = nil; expected = [.processTableUnreadable]
        case "noBootTime": boot = nil; expected = [.lostRun]
        case "journalAfterBoot": boot = Date().addingTimeInterval(-10); expected = [.lostRun]
        default:
            saved = RuntimeExecutionOwnerRecord(taskID: saved.taskID, taskOwnerID: saved.taskOwnerID, ownerID: saved.ownerID,
                executionID: saved.executionID, runID: saved.runID, appProcess: try Self.alive, providerProcess: saved.providerProcess,
                runtime: saved.runtime, sessionID: nil, state: .finished, limits: saved.limits, stopProof: saved.stopProof,
                settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
                resourceClaims: saved.resourceClaims, providerLaunchCount: 1, resourcesReleased: false, updatedAt: saved.updatedAt)
            expected = [.lostRun]
        }
        try save(saved, h); try h.context.save()
        #expect(try verdict(saved, task, h, boot: boot, now: now) == .held(expected))
        #expect(expected.allSatisfy { $0.isRunning } == ["running", "providerAlive", "survivorAlive", "newSurvivor"].contains(fault))
        // The driver changes nothing while a fact holds.
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot) { launch in
            .init(launch: launch, observedAt: Date(), complete: now != nil, survivors: now ?? [])
        }
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == saved)
        #expect(try !RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
    }

    /// A registration for the execution, as a launch with an SSH route leaves it.
    private func sshJobs(_ h: HeadlessChatHarness, task: AgentTask, owner: RuntimeExecutionOwnerRecord) throws -> RemoteWorkspaceJobStore {
        let root = RemoteWorkspaceJobRegistration.directory(taskID: task.id, executionID: owner.executionID, context: h.context)
        let receipt = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: owner.taskOwnerID).recordURL
        var config = RemoteWorkspaceJobConfiguration(recordRootPath: root.appendingPathComponent("jobs").path,
            sshExecutable: "/usr/bin/ssh", connections: [], taskID: task.id.uuidString, runID: owner.runID?.uuidString,
            ownerBinding: .init(receiptPath: receipt.path, taskID: task.id.uuidString, runID: try #require(owner.runID).uuidString,
                ownerID: owner.ownerID.uuidString, executionID: owner.executionID.uuidString))
        config.observationSSHOptions = RemoteWorkspaceJobRegistration.observationOptions(task: task)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RemoteWorkspaceJobProtectedFile.write(JSONEncoder().encode(config), to: root.appendingPathComponent("configuration.json"))
        return RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
    }

    private func sshJob(_ task: AgentTask, _ owner: RuntimeExecutionOwnerRecord, status: RemoteWorkspaceJobStatus) -> RemoteWorkspaceJobRecord {
        var job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: task.id.uuidString,
            runID: owner.runID?.uuidString, connection: .init(id: "fixture", name: "Fixture", target: "fixture", arguments: ["fixture"]),
            command: "true", createdAt: Date())
        job.ownerID = owner.ownerID.uuidString; job.executionID = owner.executionID.uuidString; job.status = status
        return job
    }

    @Test("A tool run where an SSH route was open is judged by this Mac alone",
          arguments: ["beforeBoot", "cleanTable", "survivor", "helperOnly", "noObservation"])
    func sshRouteAloneDoesNotHold(shape: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h)
        var saved = record(task, run: run)
        let mine = RuntimeLocalSurvivorObservation.Survivor(process: try Self.alive, name: "ssh")
        var boot: Date? = Date().addingTimeInterval(-600)
        let expected: RuntimeReservationRelease.Verdict
        switch shape {
        case "beforeBoot": proof(&saved, remoteExcluded: false); boot = afterEverything; expected = .release(.hostRestart)
        // The exit recorded what the process table showed, and it is asked again now.
        case "cleanTable": proof(&saved, remoteExcluded: false, survivors: observation(saved, survivors: [])); expected = .release(.processTable)
        // A local `ssh` that is still running is a survivor like any other.
        case "survivor": proof(&saved, remoteExcluded: false, survivors: observation(saved, survivors: [mine])); expected = .held([.survivors([mine])])
        // The only tool was ASTRA's SSH helper, which starts nothing here that outlives the launch.
        case "helperOnly": proof(&saved, remoteExcluded: false, managed: true); expected = .release(.exitProof)
        // A receipt from before the exit recorded this has nothing to ask the table about.
        default: proof(&saved, remoteExcluded: false); expected = .held([.lostRun])
        }
        try save(saved, h); try h.context.save()
        #expect(try verdict(saved, task, h, boot: boot) == expected)
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot) { launch in
            .init(launch: launch, observedAt: Date(), complete: true, survivors: [])
        }
        let after = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        guard case .release = expected else { #expect(after == saved); return }
        // The folder is free. Retry is not: the stop proof still says a tool
        // ran where another machine was reachable, and nothing upgraded it.
        #expect(after.resourcesReleased == true && after.stopProof == saved.stopProof && !after.canReplace)
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
    }

    @Test("An SSH job ASTRA tracks holds the reservation until it ends, and is named",
          arguments: [RemoteWorkspaceJobStatus.starting, .running, .lost, .unverified, .succeeded, .failed, .timedOut, .cancelled])
    func trackedSSHJob(status: RemoteWorkspaceJobStatus) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h)
        var saved = record(task, run: run)
        proof(&saved, remoteExcluded: false)
        try save(saved, h); try h.context.save()
        let jobs = try sshJobs(h, task: task, owner: saved)
        // The registration alone, with no job in it, holds nothing.
        #expect(try verdict(saved, task, h, boot: afterEverything) == .release(.hostRestart))
        let job = sshJob(task, saved, status: status)
        try jobs.create(job)
        #expect(try verdict(saved, task, h, boot: afterEverything)
            == (status.isTerminal ? .release(.hostRestart) : .held([.sshJobs([job.jobID])])))
        #expect(!RuntimeReservationRelease.Blocker.sshJobs([job.jobID]).isRunning)
    }

    @Test("A receipt that recorded SSH jobs holds until they can be found and have ended; the saved set stays unsettled for Retry")
    func recordedSSHJobs() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h)
        var saved = record(task, run: run)
        proof(&saved, remoteExcluded: false, managed: true)
        try save(saved, h); try h.context.save()
        let jobs = try sshJobs(h, task: task, owner: saved)
        let job = sshJob(task, saved, status: .running)
        try jobs.create(job)
        saved.pendingSSHJobSetDigest = try RuntimeWorkspaceRemoteJobs.releaseEvidence(task: task, owner: saved, context: h.context).identity
        try save(saved, h)
        let recorded = try #require(saved.pendingSSHJobSetDigest)
        #expect(try verdict(saved, task, h, boot: afterEverything) == .held([.sshJobs([job.jobID])]))
        // A record that is missing is not an ended job, and neither is a set
        // that is not the one recorded.
        let file = try jobs.recordURL(jobID: job.jobID), kept = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        #expect(try verdict(saved, task, h, boot: afterEverything) == .held([.sshJobsUnreadable]))
        try kept.write(to: file)
        let extra = sshJob(task, saved, status: .succeeded)
        try jobs.create(extra)
        #expect(try verdict(saved, task, h, boot: afterEverything) == .held([.sshJobsUnreadable]))
        try FileManager.default.removeItem(at: try jobs.recordURL(jobID: extra.jobID))
        #expect(try verdict(saved, task, h, boot: afterEverything) == .held([.sshJobs([job.jobID])]))
        try jobs.update(jobID: job.jobID) { $0.status = .succeeded }
        #expect(try verdict(saved, task, h, boot: afterEverything) == .release(.hostRestart))

        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let after = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        // The jobs ended, which ends the reservation. They were not withdrawn
        // before they started, so the saved set is not settled and Retry stays refused.
        #expect(after.resourcesReleased == true && after.pendingSSHJobSetDigest == recorded)
        #expect(after.stopProof == saved.stopProof && !after.canReplace)
    }

    @Test("What a restart answers: a stale settlement barrier, an unrecorded exit, a registration with no job",
          arguments: ["settling", "settlementTools", "unreaped", "groupNotEmpty", "registrationOnly", "runEndedLater",
                      "noExitRecord", "noExitRecordWithRegistration"])
    func restartAnswers(shape: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        var saved = record(task, run: run, state: .unverified)
        let store = RuntimeExecutionOwner.store(in: h.context)
        switch shape {
        case "settling": saved.settlementInProgress = true; saved.settlementLocalWorkStopped = false
        case "settlementTools": saved.settlementToolsStopped = false
        case "unreaped": proof(&saved, reaped: false)
        case "groupNotEmpty": proof(&saved, groupEmpty: false)
        case "registrationOnly":
            try FileManager.default.createDirectory(at: store.root.deletingLastPathComponent()
                .appendingPathComponent("remote-jobs/\(task.id.uuidString)"), withIntermediateDirectories: true)
        case "runEndedLater": run.completedAt = Date().addingTimeInterval(60)
        // ASTRA lost the run. A launch with an SSH route leaves a registration
        // folder behind, and that is not remote work either.
        case "noExitRecord": saved.stopProof = nil
        default:
            saved.stopProof = nil
            try FileManager.default.createDirectory(at: store.root.deletingLastPathComponent()
                .appendingPathComponent("remote-jobs/\(task.id.uuidString)"), withIntermediateDirectories: true)
        }
        try save(saved, h); try h.context.save()
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(released.resourcesReleased == true && released.providerSharedStateReleased == true)
        #expect(released.reservationRelease?.basis == .hostRestart && released.reservationRelease?.bootedAt != nil)
        // The folder is free; the execution is not thereby replayable.
        #expect(!released.canReplace && released.stopProof == saved.stopProof && released.state == .unverified)
        // Saved under its own entry name, which a build from before this rule never looks up.
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("reconciliations").path)
        #expect(entries == [saved.executionID.uuidString + ".reservation"])
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
        #expect(RuntimeExecutionOwner.retryDecision(task: task, context: h.context) == .blocked)
    }

    @Test("The process table answers in the same boot once the recorded survivors are gone")
    func processTableAnswers() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        var saved = record(task, run: run, state: .unverified)
        let gone = RuntimeLocalSurvivorObservation.Survivor(process: .init(pid: Int32.max - 1, startedSeconds: 1, startedMicroseconds: 1), name: "node")
        proof(&saved, survivors: observation(saved, survivors: [gone]))
        try save(saved, h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: nil) { launch in
            .init(launch: launch, observedAt: Date(), complete: true, survivors: [])
        }
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(released.resourcesReleased == true && released.reservationRelease?.basis == .processTable)
        #expect(!released.canReplace && released.stopProof == saved.stopProof)
    }

    @Test("Where the stop proof is upgraded today it still is, and the release is saved once")
    func completedOwnerKeepsItsProofUpgrade() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h)
        var original = record(task, run: run)
        original.inheritedToolUncertainty = true
        try save(original, h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let boot = afterEverything
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot)
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(released.resourcesReleased == true && released.canReplace && released.inheritedToolUncertainty == false)
        #expect(released.stopProof?.hostRestart?.bootedAt == boot && released.reservationRelease?.basis == .hostRestart)
        #expect(released.hostNoToolReconciliationOriginalProof == original.stopProof)
        #expect(TaskHistoryRead.events(for: task, ofTypes: [TaskEventTypes.System.runtimeExecutionOwnership.rawValue]).count == 1)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: boot)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == released)
        #expect(TaskHistoryRead.events(for: task, ofTypes: [TaskEventTypes.System.runtimeExecutionOwnership.rawValue]).count == 1)
    }

    @Test("Every earlier execution of the owner is asked the same question", arguments: ["clean", "sshRoute", "settlementOpen", "container"])
    func lineage(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, lastRun) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        let firstRun = run(task, h); firstRun.startedAt = Date().addingTimeInterval(-60); firstRun.completedAt = Date().addingTimeInterval(-50)
        try h.context.save()
        var first = record(task, run: firstRun)
        // A barrier an earlier execution left open, and a tool it ran with an SSH
        // route open, are answered by the restart; its container is not.
        if fault == "sshRoute" { proof(&first, remoteExcluded: false) }
        if fault == "settlementOpen" { first.settlementToolsStopped = false }
        if fault == "container" {
            var environment = WorkspaceExecutionEnvironment.host; environment.kind = .dockerImage
            firstRun.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
            try h.context.save()
        }
        var last = record(task, run: lastRun, owner: first.ownerID, state: .unverified)
        last.retainedExecutionHead = first.executionID
        let store = RuntimeExecutionOwner.store(in: h.context)
        try save(first, h); try store.retain(first); try save(last, h)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        let current = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect((current.resourcesReleased == true) == (fault != "container"))
        if fault == "container" { #expect(current == last) }
    }

    @Test("A live worker's lease is never taken, and a holder that changed is asked again later")
    func liveLease() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        let saved = record(task, run: run, state: .unverified)
        try save(saved, h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        do {
            let held = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
            #expect(try held.read() == saved)
        }
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.resourcesReleased == true)
    }

    @Test("After a failed holder is released the next task starts with no decision and inherits nothing")
    func nextTaskStarts() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        try save(record(task, run: run, state: .unverified), h)
        let queue = TaskQueue(poolSize: 0)
        let next = h.makeTask(runtime: .codexCLI, goal: "A new instruction", model: "test")
        next.workspace = task.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let claims = queue.resourceLockClaims(for: request, task: next, runMode: "request")
        let store = RuntimeExecutionOwner.store(in: h.context)
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: Date().addingTimeInterval(-600))
        queue.refreshResourceOwnership(in: h.context)
        #expect(!queue.canAcquireResourceLocks(claims))
        try RuntimeReservationRelease.reconcile(in: store, context: h.context, bootedAt: afterEverything)
        queue.refreshResourceOwnership(in: h.context)
        #expect(queue.canAcquireResourceLocks(claims))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: next, context: h.context, maxRunSeconds: 60, userRequest: request))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == nil && owner.record.inheritedToolUncertainty == false)
    }

    @Test("While a request waits the rule is asked on every tenth pass, and ownership is re-read only after a release")
    func waitingLoopAsksTheRule() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h, status: .failed, reason: .providerRunWallClockExceeded)
        var saved = record(task, run: run, state: .unverified)
        try save(saved, h)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let next = h.makeTask(runtime: .codexCLI, goal: "A new instruction", model: "test")
        next.workspace = task.workspace
        let claims = queue.resourceLockClaims(for: nil, task: next, runMode: "task")
        #expect(!queue.canAcquireResourceLocks(claims))
        // Stands in for the fact changing: the exit record now shows nothing was left.
        proof(&saved, toolsStopped: true)
        try save(saved, h)
        for _ in 1..<TaskQueue.waitingOwnershipRefreshInterval { queue.refreshOwnershipWhileWaiting(blocked: true, in: h.context) }
        #expect(!queue.canAcquireResourceLocks(claims))
        // Nothing waiting starts the count again.
        queue.refreshOwnershipWhileWaiting(blocked: false, in: h.context)
        queue.refreshOwnershipWhileWaiting(blocked: true, in: h.context)
        #expect(!queue.canAcquireResourceLocks(claims))
        for _ in 1..<TaskQueue.waitingOwnershipRefreshInterval { queue.refreshOwnershipWhileWaiting(blocked: true, in: h.context) }
        #expect(queue.canAcquireResourceLocks(claims))
        let released = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(released.resourcesReleased == true && released.reservationRelease?.basis == .exitProof && !released.canReplace)
    }

    @Test("Receipts written before the release record existed decode and encode unchanged")
    func olderReceipts() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, run) = try holder(h)
        let saved = record(task, run: run)
        let data = try JSONEncoder().encode(saved)
        #expect(!String(decoding: data, as: UTF8.self).contains("reservationRelease"))
        #expect(try JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: data) == saved)
    }

    @Test("A release that a person decided, as a later build writes it, is read and kept whole")
    func decidedRelease() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run) = try holder(h)
        var saved = record(task, run: run)
        saved.resourcesReleased = true
        try save(saved, h)
        // The bytes the later build leaves in the journal.
        let store = RuntimeExecutionOwner.store(in: h.context)
        let url = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID).recordURL
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let request = UUID()
        json["reservationRelease"] = ["basis": "decision", "requestID": request.uuidString, "named": ["process:keyboxd:4821", "ssh_job:abc"]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        // Every admission lists every receipt, so one that cannot be read stops them all.
        let read = try #require(try store.records().first { $0.taskID == task.id })
        #expect(read.reservationRelease == .init(basis: .decision, requestID: request, named: ["process:keyboxd:4821", "ssh_job:abc"]))
        #expect(try JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: JSONEncoder().encode(read)) == read)
        #expect(RuntimeCompletedUserTurnContinuation.hasEndedReservation(read, task: task, context: h.context))
        // The rule leaves it alone: it holds nothing to release.
        #expect(try RuntimeReservationRelease.reconcile(in: store, context: h.context) == 0)
        #expect(try store.records().first { $0.taskID == task.id } == read)
        // A basis this build does not know cannot be read at all, which is
        // why that one is declared here ahead of the build that writes it.
        // A launch in any test checks every registered journal folder, so
        // this one leaves the registry before it holds an unreadable receipt.
        RuntimeProviderResourceRegistry.unregister(store.root)
        json["reservationRelease"] = ["basis": "not_known_here"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(throws: (any Error).self) { try store.records() }
    }
}
