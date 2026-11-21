import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

/// "Review workspace" asks the one release rule about every task that holds
/// the folder a request waits for. A holder that is itself still at work
/// refuses. Anything else the rule cannot answer, and a process a finished
/// holder left behind, is named to the person, who may start past it. Their
/// decision ends the holders' reservations, so the request then starts like
/// any other and nothing is remembered.
@Suite("Review workspace: a person starts past what ASTRA cannot answer", .serialized)
@MainActor
struct RuntimeWorkspaceReviewTests {
    private typealias Survivor = RuntimeLocalSurvivorObservation.Survivor
    private static let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
    private static var alive: RuntimeProcessIdentity {
        get throws { try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)) }
    }
    /// Nothing here is answered by a restart: the boot is long before every receipt.
    private let boot = Date().addingTimeInterval(-600)

    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    private func proof(_ record: inout RuntimeExecutionOwnerRecord, process: RuntimeProcessIdentity? = nil, reaped: Bool = true,
                       groupEmpty: Bool = true, managed: Bool? = nil, survivors: RuntimeLocalSurvivorObservation? = nil) {
        let old = record.stopProof!
        var value = RuntimeExecutionStopProof(executionID: old.executionID, process: process ?? old.process, reaped: reaped,
            processGroupEmpty: groupEmpty, toolsStopped: false, remoteWorkExcluded: true, capturedAt: old.capturedAt, managedSSHOnly: managed)
        value.localSurvivors = survivors
        record.stopProof = value
    }

    private func observation(_ record: RuntimeExecutionOwnerRecord, _ found: [Survivor]) -> RuntimeLocalSurvivorObservation {
        .init(launch: .init(scope: UUID().uuidString, root: "/tmp", provider: record.providerProcess!, ended: record.stopProof!.capturedAt),
              observedAt: record.stopProof!.capturedAt, complete: true, survivors: found)
    }

    /// A task whose last run ended on this Mac: provider reaped, group empty,
    /// and a transcript that could not show its tools stopped.
    private func holder(_ h: HeadlessChatHarness, title: String = "Export report", status: RunStatus = .completed,
                        reason: TaskRunStopReason = .completed,
                        change: (inout RuntimeExecutionOwnerRecord, TaskRun) throws -> Void = { _, _ in }) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        task.title = title
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-25)
        run.status = status; run.typedStopReason = reason; run.completedAt = Date().addingTimeInterval(-20)
        run.setOutput("Preserved answer")
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = status == .completed ? .completed : .failed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished; record.providerLaunchCount = 1
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        try change(&record, run)
        try save(record, h); try h.context.save()
        return (task, record)
    }

    private func next(_ h: HeadlessChatHarness, after task: AgentTask) throws -> (AgentTask, TaskTurnRequest) {
        let next = h.makeTask(runtime: .codexCLI, goal: "A new instruction", model: "test")
        next.workspace = task.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        return (next, try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context)))
    }

    /// now is what the process table shows when it is asked; nil is a table that cannot be read.
    private func preview(_ h: HeadlessChatHarness, _ task: AgentTask, _ request: TaskTurnRequest,
                         now: [Survivor]? = [], enforcement: ExecutionSandboxEnforcement = .off) throws -> RuntimeWorkspaceReview.Review? {
        try RuntimeWorkspaceReview.preview(task: task, request: request, context: h.context, sandboxEnforcement: enforcement, bootedAt: boot) { launch in
            .init(launch: launch, observedAt: Date(), complete: now != nil, survivors: now ?? [])
        }
    }

    private func start(_ h: HeadlessChatHarness, _ review: RuntimeWorkspaceReview.Review, _ task: AgentTask,
                       _ request: TaskTurnRequest, now: [Survivor]? = []) throws {
        try RuntimeWorkspaceReview.start(review, task: task, request: request, context: h.context, sandboxEnforcement: .off, bootedAt: boot) { launch in
            .init(launch: launch, observedAt: Date(), complete: now != nil, survivors: now ?? [])
        }
    }

    private func journal(_ task: AgentTask, _ h: HeadlessChatHarness) throws -> Data {
        try Data(contentsOf: RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID).recordURL)
    }

    private func reconciliations(_ h: HeadlessChatHarness) -> [String] {
        let directory = RuntimeExecutionOwner.store(in: h.context).root.appendingPathComponent("reconciliations")
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    @Test("A person starts past a holder whose run ended, whatever its outcome; the request then starts like any other",
          arguments: [RunStatus.completed, .failed, .timeout, .budgetExceeded, .cancelled])
    func startsPastEndedHolder(status: RunStatus) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let reason: TaskRunStopReason = status == .completed ? .completed : status == .cancelled ? .cancelled
            : status == .timeout ? .providerRunWallClockExceeded : status == .budgetExceeded ? .maxBudgetReached : .capabilitySessionExpired
        let (a, original) = try holder(h, status: status, reason: reason) { record, _ in
            if status == .cancelled { record.cancellationRequested = true }
        }
        let (b, request) = try next(h, after: a)
        let (c, other) = try next(h, after: a)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: b, runMode: "initial", sandboxEnforcement: .off)
        #expect(!queue.canAcquireResourceLocks(claims, task: b, context: h.context))

        let review = try #require(try preview(h, b, request))
        #expect(review.holders.map(\.receipt) == [original] && review.holders.first?.blockers == [.lostRun])
        #expect(review.canStart && review.holders.first?.title == "Export report")
        // Looking changes nothing.
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == original && reconciliations(h).isEmpty)

        try start(h, review, b, request)
        let released = try #require(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID))
        #expect(released.resourcesReleased == true && released.providerSharedStateReleased == true)
        #expect(released.reservationRelease == .init(basis: .decision, requestID: request.id, named: ["lost_run"]))
        // The decision certifies nothing about the holder's work: its exit
        // record, its run and its outcome are as they were, and Retry stays refused.
        var expected = original
        expected.resourcesReleased = true; expected.providerSharedStateReleased = true
        expected.reservationRelease = released.reservationRelease; expected.updatedAt = released.updatedAt
        #expect(released == expected && released.stopProof == original.stopProof && !released.canReplace)
        #expect(a.runs.first?.status == status && a.runs.first?.output == "Preserved answer")
        #expect(RuntimeExecutionOwner.acquire(task: a, context: h.context, maxRunSeconds: 60) == nil)
        #expect(reconciliations(h) == [original.executionID.uuidString + ".reservation"])
        #expect(a.events.contains { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.hasPrefix("You let other tasks use `") })
        let decided = try #require(b.events.first { $0.type == TaskEventTypes.System.runtimeWorkspaceContinuationAuthorized.rawValue })
        #expect(decided.payload.contains(original.executionID.uuidString) && decided.payload.contains("lost_run"))

        // Nothing is remembered and nothing is inherited: the folder is
        // simply free. A second task is not asked, and the first starts
        // through ordinary admission.
        #expect(try preview(h, c, other) == nil)
        #expect(try store.workspaceContinuation(requestID: request.id) == nil)
        queue.refreshResourceOwnership(in: h.context)
        #expect(queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context,
            maxRunSeconds: 60, userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == nil && owner.record.inheritedToolUncertainty == false)
        // While the first works, the second waits for it, and that is not a decision either.
        let waiting = try #require(try preview(h, c, other))
        #expect(!waiting.canStart && waiting.holders.map(\.taskID) == [b.id] && waiting.holders.first?.blockers == [.taskWorking])
    }

    @Test("A holder released by a decision accepts its own next message; its Retry stays refused")
    func releasedHolderContinues() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h, status: .failed, reason: .capabilitySessionExpired)
        let (b, request) = try next(h, after: a)
        try start(h, try #require(try preview(h, b, request)), b, request)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context)?.canReplace == false)
        let follow = try ExecutionRequestSubmissionService.submitFollowUp(message: "Carry on", for: a, into: h.context).get()
        let message = try #require(try TaskTurnRequestRepository.request(id: follow.requestID, in: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: a, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true, userRequest: message))
        owner.finish()
    }

    @Test("A holder that is itself still at work cannot be started past, and says what runs",
          arguments: ["running", "newerRun", "liveLease", "providerAlive", "settling"])
    func activeHolderRefuses(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let me = try Self.alive
        let (a, saved) = try holder(h) { record, run in
            switch fault {
            case "running": run.status = .running
            case "providerAlive": record.providerProcess = me; proof(&record, process: me)
            case "settling":
                // ASTRA itself is still closing the run.
                record = RuntimeExecutionOwnerRecord(taskID: record.taskID, taskOwnerID: record.taskOwnerID, ownerID: record.ownerID,
                    executionID: record.executionID, runID: record.runID, appProcess: me, providerProcess: record.providerProcess,
                    runtime: record.runtime, sessionID: nil, state: .finished, limits: record.limits, stopProof: record.stopProof,
                    settlementInProgress: true, settlementLocalWorkStopped: true, settlementToolsStopped: true,
                    resourceClaims: record.resourceClaims, providerLaunchCount: 1, resourcesReleased: false, updatedAt: record.updatedAt)
            default: break
            }
        }
        if fault == "newerRun" {
            let later = TaskRun(task: a); later.startedAt = Date().addingTimeInterval(60); later.status = .running
            h.context.insert(later); try h.context.save()
        }
        let store = RuntimeExecutionOwner.store(in: h.context)
        var live: RuntimeExecutionOwnerStore.Lease?
        defer { withExtendedLifetime(live) {} }
        if fault == "liveLease" { live = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID) }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        let expected: RuntimeReservationRelease.Blocker = fault == "providerAlive" ? .providerAlive(pid: me.pid)
            : fault == "settling" ? .settling : .taskWorking
        #expect(!review.canStart && review.holders.first?.blockers.contains(expected) == true)
        let dialog = RuntimeWorkspaceReviewWording.dialog(review)
        #expect(!dialog.canStart && dialog.title.hasPrefix("Something is still running in "))
        #expect(dialog.message.contains("“Export report”") && !dialog.message.contains("Starting now"))
        #expect(throws: (any Error).self) { try start(h, review, b, request) }
        live = nil
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == saved && reconciliations(h).isEmpty)
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    @Test("Each thing ASTRA cannot answer is named, and a person may start past it", arguments: [
        "unreaped", "groupNotEmpty", "settlementTools", "settlementLocalWork", "interruptedSettlement", "noPlacement",
        "container", "tableUnreadable", "sessionPending"])
    func unknownsAreNamed(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        var now: [Survivor]? = []
        let gone = Survivor(process: .init(pid: Int32.max - 1, startedSeconds: 1, startedMicroseconds: 1), name: "node")
        let (a, original) = try holder(h) { record, run in
            switch fault {
            case "unreaped": proof(&record, reaped: false)
            case "groupNotEmpty": proof(&record, groupEmpty: false)
            case "settlementTools": record.settlementToolsStopped = false
            case "settlementLocalWork": record.settlementLocalWorkStopped = false
            // The ASTRA process that was closing the run is gone.
            case "interruptedSettlement": record.settlementInProgress = true
            case "noPlacement": run.executionEnvironmentSnapshotJSON = nil
            case "container":
                var environment = WorkspaceExecutionEnvironment.host; environment.kind = .dockerImage
                run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
            case "tableUnreadable": proof(&record, survivors: observation(record, [gone])); now = nil
            default: record.sessionVerificationPending = true
            }
        }
        let expected: [RuntimeReservationRelease.Blocker]
        switch fault {
        case "settlementTools", "settlementLocalWork", "interruptedSettlement": expected = [.settlementUnconfirmed, .lostRun]
        case "noPlacement": expected = [.placementUnrecorded, .lostRun]
        case "container": expected = [.container, .lostRun]
        case "tableUnreadable": expected = [.processTableUnreadable]
        case "sessionPending": expected = [.sessionUnverified, .lostRun]
        default: expected = [.lostRun]
        }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request, now: now))
        #expect(review.holders.first?.blockers == expected && review.canStart)
        let dialog = RuntimeWorkspaceReviewWording.dialog(review)
        #expect(dialog.canStart && dialog.title.hasPrefix("Start in ") && dialog.title.hasSuffix(" now?"))
        try start(h, review, b, request, now: now)
        let released = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
        #expect(released.resourcesReleased == true && released.stopProof == original.stopProof && !released.canReplace)
        #expect(released.reservationRelease?.basis == .decision && released.reservationRelease?.named == expected.flatMap(\.auditNames))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
        owner.finish()
    }

    @Test("A process a finished holder left behind is named, and a person may start past it")
    func leftoverProcessIsNamed() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let mine = Survivor(process: try Self.alive, name: "python3")
        let (a, original) = try holder(h) { record, _ in proof(&record, survivors: observation(record, [mine])) }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        #expect(review.canStart && review.holders.first?.blockers == [.survivors([mine])])
        let dialog = RuntimeWorkspaceReviewWording.dialog(review)
        #expect(dialog.canStart && dialog.message.contains("“Export report” has ended, but python3 (process \(mine.process.pid)), which it started, is still running."))
        #expect(dialog.message.contains("Starting now does not stop it, and it can still change files there."))
        try start(h, review, b, request)
        let released = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
        #expect(released.reservationRelease == .init(basis: .decision, requestID: request.id, named: ["process:python3:\(mine.process.pid)"]))
        #expect(released.stopProof == original.stopProof && !released.canReplace)
        // The process was neither signalled nor forgotten: it is still on record as running.
        #expect(released.stopProof?.localSurvivors?.survivors == [mine] && mine.process.presence == .present)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
        owner.finish()
    }

    @Test("A leftover process that exits, or a new one that appears, while the dialog is open is not decided on the old answer",
          arguments: ["exited", "appeared"])
    func leftoverProcessChanges(change: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let first = Survivor(process: try Self.alive, name: "python3")
        let second = Survivor(process: .init(pid: first.process.pid + 1, startedSeconds: 2, startedMicroseconds: 2), name: "node")
        // The exit saw nothing left; the process table is what shows one now.
        let (a, original) = try holder(h) { record, _ in proof(&record, survivors: observation(record, [])) }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request, now: [first]))
        #expect(review.holders.first?.blockers == [.survivors([first])])
        if change == "exited" {
            // Nothing is left, so the rule ends the reservation and no decision is recorded.
            try start(h, review, b, request, now: [])
            let released = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
            #expect(released.resourcesReleased == true && released.reservationRelease?.basis == .processTable)
            #expect(!b.events.contains { $0.type == TaskEventTypes.System.runtimeWorkspaceContinuationAuthorized.rawValue })
        } else {
            #expect(throws: (any Error).self) { try start(h, review, b, request, now: [second, first]) }
            #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == original && reconciliations(h).isEmpty)
            // Asked again, it names both.
            let again = try #require(try preview(h, b, request, now: [second, first]))
            #expect(again.holders.first?.blockers == [.survivors([first, second])])
        }
    }

    private func sshJob(_ h: HeadlessChatHarness, task: AgentTask, owner: RuntimeExecutionOwnerRecord, label: String?) throws -> RemoteWorkspaceJobRecord {
        let root = RemoteWorkspaceJobRegistration.directory(taskID: task.id, executionID: owner.executionID, context: h.context)
        let receipt = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: owner.taskOwnerID).recordURL
        var config = RemoteWorkspaceJobConfiguration(recordRootPath: root.appendingPathComponent("jobs").path,
            sshExecutable: "/usr/bin/ssh", connections: [], taskID: task.id.uuidString, runID: owner.runID?.uuidString,
            ownerBinding: .init(receiptPath: receipt.path, taskID: task.id.uuidString, runID: try #require(owner.runID).uuidString,
                ownerID: owner.ownerID.uuidString, executionID: owner.executionID.uuidString))
        config.observationSSHOptions = RemoteWorkspaceJobRegistration.observationOptions(task: task)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RemoteWorkspaceJobProtectedFile.write(JSONEncoder().encode(config), to: root.appendingPathComponent("configuration.json"))
        var job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: task.id.uuidString,
            runID: owner.runID?.uuidString, connection: .init(id: "fixture", name: "build-host", target: "fixture", arguments: ["fixture"]),
            command: "true", createdAt: Date())
        job.ownerID = owner.ownerID.uuidString; job.executionID = owner.executionID.uuidString
        job.status = .running; job.label = label
        try RemoteWorkspaceJobStore(rootPath: config.recordRootPath).create(job)
        return job
    }

    @Test("An SSH job that has not ended is named by its label and host, and a person may start past it", arguments: [true, false])
    func openSSHJobIsNamed(labelled: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        // The only tool was ASTRA's SSH helper, which starts nothing on this Mac that outlives the launch.
        let (a, original) = try holder(h) { record, _ in proof(&record, managed: true) }
        let job = try sshJob(h, task: a, owner: original, label: labelled ? "Nightly export" : nil)
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        #expect(review.canStart && review.holders.first?.blockers == [.sshJobs([job.jobID])])
        let names = RuntimeWorkspaceRemoteJobs.names(task: a, owner: original, context: h.context)
        #expect(names[job.jobID]?.host == "build-host" && names[job.jobID]?.label == job.label)
        let dialog = RuntimeWorkspaceReviewWording.dialog(review, jobs: names.mapValues { .init(label: $0.label, host: $0.host) })
        let named = labelled ? "“Nightly export” on build-host" : "\(job.jobID.prefix(8)) on build-host"
        #expect(dialog.message.contains("“Export report” has an SSH job that has not ended: \(named). Starting now does not stop it."))
        try start(h, review, b, request)
        let released = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
        #expect(released.resourcesReleased == true && released.reservationRelease?.named == ["ssh_job:\(job.jobID)"] && !released.canReplace)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
        owner.finish()
    }

    @Test("Anything that changes while the dialog is open refuses the decision, and nothing is written for any holder",
          arguments: ["changed", "liveLease", "running", "newHolder", "otherRequest"])
    func changeRefusesEveryHolder(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, first) = try holder(h, title: "Export report")
        let (other, second) = try holder(h, title: "Clean data")
        other.workspace = a.workspace; try h.context.save()
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        #expect(Set(review.holders.map(\.taskID)) == [a.id, other.id] && review.canStart)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var live: RuntimeExecutionOwnerStore.Lease?
        defer { withExtendedLifetime(live) {} }
        var changed = second
        var asked = request
        switch fault {
        case "changed": changed.limits.tokensSpent += 1; try save(changed, h)
        case "liveLease": live = try store.acquire(taskID: other.id, taskOwnerID: other.persistentModelID)
        case "running": other.runs.first?.status = .running; try h.context.save()
        case "newHolder":
            let (third, _) = try holder(h, title: "Late arrival"); third.workspace = a.workspace; try h.context.save()
        default: asked = try next(h, after: a).1
        }
        #expect(throws: (any Error).self) { try start(h, review, b, asked) }
        live = nil
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == first)
        #expect(try store.read(taskID: other.id, taskOwnerID: other.persistentModelID) == changed)
        #expect(reconciliations(h).isEmpty)
        #expect(!b.events.contains { $0.type == TaskEventTypes.System.runtimeWorkspaceContinuationAuthorized.rawValue })
    }

    @Test("The release refuses a holder at work, an answer that no longer holds, a changed holder and one with nothing to decide, whoever asks",
          arguments: ["active", "staleAnswer", "nothingToDecide", "changedReceipt"])
    func releaseRefuses(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try holder(h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var saved = original
        var reviewed = RuntimeReservationRelease.Reviewed(receipt: original, blockers: [.lostRun])
        switch fault {
        // The answer is exactly what the rule says now, and it still may not be decided past.
        case "active": a.runs.first?.status = .running; try h.context.save(); reviewed = .init(receipt: original, blockers: [.taskWorking, .lostRun])
        case "staleAnswer": reviewed = .init(receipt: original, blockers: [.container])
        case "nothingToDecide": reviewed = .init(receipt: original, blockers: [])
        default: saved.limits.tokensSpent += 1; try save(saved, h)
        }
        #expect(throws: (any Error).self) {
            try RuntimeReservationRelease.release([reviewed], decidedFor: UUID(), store: store, context: h.context, bootedAt: boot)
        }
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == saved && reconciliations(h).isEmpty)
    }

    @Test("A copy of the waiting task under the same ID is not another task to decide about")
    func sameIDCopyIsNotAHolder() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h)
        let (b, request) = try next(h, after: a)
        let (copy, held) = try holder(h, title: "Imported copy")
        // The copy's row and record carry the waiting task's ID.
        do {
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: copy.id, taskOwnerID: copy.persistentModelID)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        copy.id = b.id; try h.context.save()
        var moved = held
        moved = RuntimeExecutionOwnerRecord(taskID: b.id, taskOwnerID: copy.persistentModelID, ownerID: held.ownerID,
            executionID: held.executionID, runID: held.runID, appProcess: held.appProcess, providerProcess: held.providerProcess,
            runtime: held.runtime, sessionID: nil, state: .finished, limits: held.limits, stopProof: held.stopProof,
            settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
            resourceClaims: held.resourceClaims?.map { .init(taskID: b.id, resourceKey: $0.resourceKey, accessMode: $0.accessMode, runMode: $0.runMode, resourceKind: $0.resourceKind) },
            providerLaunchCount: 1, resourcesReleased: false, updatedAt: held.updatedAt)
        try save(moved, h)
        #expect(throws: (any Error).self) { try preview(h, b, request) }
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: b.id, taskOwnerID: copy.persistentModelID) == moved)
    }

    @Test("Only a request a person wrote is asked about; a schedule, a chained task and a cancelled request are not",
          arguments: ["scheduled", "scheduleSource", "chained", "cancelled", "otherTask"])
    func onlyAPersonsRequest(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try holder(h)
        let (b, request) = try next(h, after: a)
        #expect(RuntimeWorkspaceReview.qualifies(request, task: b, context: h.context))
        var asker = b
        let source = try #require(TaskHistoryRead.event(id: request.sourceEventID, in: b))
        switch fault {
        case "scheduled": request.kind = .scheduled
        case "scheduleSource": source.payload = TaskEvent.payloadString(TaskExecutionSourcePayloadV1(launchMode: .initial, scheduleID: UUID()))
        case "chained": source.payload = TaskEvent.payloadString(TaskExecutionSourcePayloadV1(launchMode: .initial, sourceTaskID: a.id))
        case "cancelled": _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled)
        default: asker = try next(h, after: a).0
        }
        try h.context.save()
        #expect(!RuntimeWorkspaceReview.qualifies(request, task: asker, context: h.context))
        #expect(throws: (any Error).self) { try preview(h, asker, request) }
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == original && reconciliations(h).isEmpty)
    }

    @Test("A decision frees everything the holder was using, and the dialog says which other folders that is")
    func decisionFreesTheWholeHolder() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("astra-review-worktree-\(UUID().uuidString)/earlier")
        let (a, _) = try holder(h) { record, _ in
            record.resourceClaims = (record.resourceClaims ?? []) + [
                .init(taskID: record.taskID, resourceKey: worktree.path, accessMode: .write, runMode: "previous"),
                .init(taskID: record.taskID, resourceKey: "shared-browser", accessMode: .write, runMode: "previous", resourceKind: .browserSession)]
        }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        let holder = try #require(review.holders.first)
        #expect(holder.otherClaims.contains { $0.resourceKey == worktree.path } && !holder.claims.contains { $0.resourceKey == worktree.path })
        let dialog = RuntimeWorkspaceReviewWording.dialog(review)
        #expect(dialog.message.contains("Starting now also frees earlier, which “Export report” was using."))
        try start(h, review, b, request)
        let store = RuntimeExecutionOwner.store(in: h.context)
        #expect(try !RuntimeResourceOwnership.claims(in: store, context: h.context).contains { $0.taskID == a.id })
    }

    @Test("A fence that no readable record accounts for is not something a person can decide about")
    func unaccountedFenceCannotBeDecided() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try holder(h)
        // Only the task's history still says what it reserved.
        h.context.insert(TaskEvent(task: a, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: TaskEvent.payloadString(original, fallback: "{}"), run: a.runs.first))
        let store = RuntimeExecutionOwner.store(in: h.context)
        do {
            let lease = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        try h.context.save()
        let (b, request) = try next(h, after: a)
        try #require(try !RuntimeResourceOwnership.claims(in: store, context: h.context, excluding: b.id, excludingOwner: b.persistentModelID).isEmpty)
        #expect(throws: (any Error).self) { try preview(h, b, request) }
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    @Test("A holder the rule can answer is released without a decision when the review opens")
    func ruleAnswersWithoutADecision() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h) { record, _ in proof(&record, survivors: observation(record, [])) }
        let (b, request) = try next(h, after: a)
        // The exit recorded a clean process table, and it is still clean.
        #expect(try preview(h, b, request, now: []) == nil)
        let released = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
        #expect(released.resourcesReleased == true && released.reservationRelease == .init(basis: .processTable))
        #expect(!b.events.contains { $0.type == TaskEventTypes.System.runtimeWorkspaceContinuationAuthorized.rawValue })
    }

    @Test("A decision is shown every run of the holder, not only the last: an earlier run's live provider refuses, and what it left is named",
          arguments: ["providerAlive", "survivor", "container"])
    func earlierRunsAreAsked(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let me = try Self.alive
        let mine = Survivor(process: me, name: "python3")
        // The last run is one ASTRA lost track of. That alone holds the folder,
        // and the rule stops there; a person deciding is shown the run before it too.
        let (a, last) = try holder(h) { record, _ in proof(&record, reaped: false) }
        let earlier = TaskRun(task: a)
        earlier.startedAt = Date().addingTimeInterval(-90); earlier.completedAt = Date().addingTimeInterval(-80)
        earlier.status = .completed; earlier.typedStopReason = .completed
        var environment = WorkspaceExecutionEnvironment.host
        if fault == "container" { environment.kind = .dockerImage }
        earlier.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        h.context.insert(earlier); try h.context.save()
        let execution = UUID()
        let provider = fault == "providerAlive" ? me : Self.dead
        var first = RuntimeExecutionOwnerRecord(taskID: last.taskID, taskOwnerID: last.taskOwnerID, ownerID: last.ownerID,
            executionID: execution, runID: earlier.id, appProcess: last.appProcess, providerProcess: provider,
            runtime: last.runtime, sessionID: nil, state: .finished, limits: last.limits,
            stopProof: RuntimeExecutionStopProof(executionID: execution, process: provider, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date().addingTimeInterval(-80), managedSSHOnly: nil),
            settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
            resourceClaims: last.resourceClaims, providerLaunchCount: 1, resourcesReleased: false, updatedAt: Date().addingTimeInterval(-80))
        if fault == "survivor" { proof(&first, survivors: observation(first, [mine])) }
        var current = last
        current.retainedExecutionHead = first.executionID
        let store = RuntimeExecutionOwner.store(in: h.context)
        try save(first, h); try store.retain(first); try save(current, h)

        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        let found = try #require(review.holders.first).blockers
        switch fault {
        case "providerAlive":
            #expect(found == [.lostRun, .providerAlive(pid: me.pid)] && !review.canStart)
            #expect(!RuntimeWorkspaceReviewWording.dialog(review).canStart)
            #expect(throws: (any Error).self) { try start(h, review, b, request) }
            #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == current && reconciliations(h).isEmpty)
        case "survivor":
            #expect(found == [.lostRun, .survivors([mine])] && review.canStart)
            #expect(RuntimeWorkspaceReviewWording.dialog(review).message.contains("python3 (process \(me.pid)), which it started, is still running."))
            try start(h, review, b, request)
            let released = try #require(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID))
            #expect(released.reservationRelease?.named == ["lost_run", "process:python3:\(me.pid)"])
        default:
            #expect(found == [.lostRun, .container] && review.canStart)
            #expect(RuntimeWorkspaceReviewWording.dialog(review).message.contains("ran in a container that ASTRA cannot look inside"))
        }
        // The rule itself still stops at the last run: it has no decision to disclose.
        let journal = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID).recordURL
        if fault != "survivor" {
            #expect(RuntimeReservationRelease.verdict(current, task: a, journal: journal, store: store, context: h.context, bootedAt: boot)
                == .held([.lostRun]))
        }
    }

    @Test("What a leftover process started while the dialog was open is named before anything is decided")
    func leftoverProcessStartsAnother() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let first = Survivor(process: try Self.alive, name: "python3")
        let second = Survivor(process: .init(pid: first.process.pid + 1, startedSeconds: 2, startedMicroseconds: 2), name: "node")
        // The exit recorded one process, and it is still there.
        let (a, original) = try holder(h) { record, _ in proof(&record, survivors: observation(record, [first])) }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request, now: [first]))
        #expect(review.holders.first?.blockers == [.survivors([first])])
        // It starts another one while the dialog is open: the old answer is not decided on.
        #expect(throws: (any Error).self) { try start(h, review, b, request, now: [first, second]) }
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == original && reconciliations(h).isEmpty)
        let again = try #require(try preview(h, b, request, now: [first, second]))
        #expect(again.holders.first?.blockers == [.survivors([first, second])])
        // A process table that cannot be read keeps the one already known.
        let unread = try #require(try preview(h, b, request, now: nil))
        #expect(unread.holders.first?.blockers == [.processTableUnreadable, .survivors([first])])
    }

    @Test("The last look at who holds the folders, and the releases, happen inside the admission fence")
    func startLooksInsideTheAdmissionFence() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let mine = Survivor(process: try Self.alive, name: "python3")
        let (a, _) = try holder(h) { record, _ in proof(&record, survivors: observation(record, [mine])) }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        let store = RuntimeExecutionOwner.store(in: h.context)
        var looks = 0, fenced = 0
        try RuntimeWorkspaceReview.start(review, task: b, request: request, context: h.context, sandboxEnforcement: .off, bootedAt: boot) { launch in
            looks += 1
            // Another ASTRA instance cannot publish a holder while this looks and writes.
            do { let other = try store.acquireAdmission(); withExtendedLifetime(other) {} } catch { fenced += 1 }
            return .init(launch: launch, observedAt: Date(), complete: true, survivors: [])
        }
        #expect(looks >= 2 && fenced == looks)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context)?.reservationRelease?.basis == .decision)
    }

    private func claims(_ request: TaskTurnRequest, _ value: [TaskExecutionResourceClaim], _ h: HeadlessChatHarness) throws {
        request.resourceClaimsJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try h.context.save()
    }

    @Test("The review sees the claims the queue admits by: a reader is in the way only when nothing enforces reading")
    func reviewUsesTheQueuesEnforcement() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        // A holder that only read the folder, and a waiting request that only reads it too.
        let (a, _) = try holder(h) { record, _ in
            record.resourceClaims = record.resourceClaims?.map {
                .init(taskID: $0.taskID, resourceKey: $0.resourceKey, accessMode: .readOnly, runMode: $0.runMode, resourceKind: $0.resourceKind)
            }
        }
        let (b, request) = try next(h, after: a)
        try claims(request, TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: b).map {
            TaskExecutionResourceClaim(kind: $0.kind, key: $0.key, access: .shared)
        }, h)
        // With a sandbox two readers share the folder: there is nothing to review.
        #expect(try preview(h, b, request, enforcement: .bestEffort) == nil)
        // With sandboxing Off a reader is admitted as a writer, and the holder is in its way.
        #expect(try preview(h, b, request, enforcement: .off)?.holders.map(\.taskID) == [a.id])
    }

    @Test("Only a folder brings a request to the review: a browser profile another task still holds is not decided here")
    func onlyFoldersAreReviewed() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("astra-review-elsewhere-\(UUID().uuidString)")
        // A holder in another folder, which also holds a browser profile.
        let (a, original) = try holder(h) { record, _ in
            record.resourceClaims = [
                .init(taskID: record.taskID, resourceKey: elsewhere.path, accessMode: .write, runMode: "previous"),
                .init(taskID: record.taskID, resourceKey: "shared-browser", accessMode: .write, runMode: "previous", resourceKind: .browserSession)]
        }
        let (b, request) = try next(h, after: a)
        try claims(request, TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: b)
            + [TaskExecutionResourceClaim(kind: .browserSession, key: "shared-browser", access: .exclusive)], h)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let wanted = queue.resourceLockClaims(for: request, task: b, runMode: "request", sandboxEnforcement: .off)
        // The request does wait for that holder, but not for a folder.
        #expect(!queue.canAcquireResourceLocks(wanted, task: b, context: h.context))
        #expect(try preview(h, b, request) == nil)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == original && reconciliations(h).isEmpty)
    }

    @Test("Two copies of one task that both hold the folder are released by one decision")
    func copiesOfOneHolderAreReleasedTogether() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, first) = try holder(h, title: "Export report")
        let (copy, held) = try holder(h, title: "Imported copy")
        let store = RuntimeExecutionOwner.store(in: h.context)
        // The copy's row and record carry the first holder's ID. Both share one lock file.
        do {
            let lease = try store.acquire(taskID: copy.id, taskOwnerID: copy.persistentModelID)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        copy.id = a.id; try h.context.save()
        let moved = RuntimeExecutionOwnerRecord(taskID: a.id, taskOwnerID: copy.persistentModelID, ownerID: held.ownerID,
            executionID: held.executionID, runID: held.runID, appProcess: held.appProcess, providerProcess: held.providerProcess,
            runtime: held.runtime, sessionID: nil, state: .finished, limits: held.limits, stopProof: held.stopProof,
            settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
            resourceClaims: first.resourceClaims, providerLaunchCount: 1, resourcesReleased: false, updatedAt: held.updatedAt)
        try save(moved, h)
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        #expect(Set(review.holders.map(\.receipt.executionID)) == [first.executionID, moved.executionID] && review.canStart)
        try start(h, review, b, request)
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID)?.reservationRelease?.basis == .decision)
        #expect(try store.read(taskID: a.id, taskOwnerID: copy.persistentModelID)?.reservationRelease?.basis == .decision)
        #expect(try preview(h, b, request) == nil)
    }

    @Test("Each holder's history names the folders that holder gave up, not another holder's")
    func eachHolderIsToldItsOwnFolders() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("astra-review-\(UUID().uuidString)/dataset")
        let (a, _) = try holder(h, title: "Export report")
        // A second holder, of another folder the request also names.
        let (other, _) = try holder(h, title: "Clean data") { record, _ in
            record.resourceClaims = [.init(taskID: record.taskID, resourceKey: data.path, accessMode: .write, runMode: "previous")]
        }
        let (b, request) = try next(h, after: a)
        try claims(request, TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: b)
            + [TaskExecutionResourceClaim(kind: .workspace, key: data.path, access: .exclusive)], h)
        let review = try #require(try preview(h, b, request))
        #expect(Set(review.holders.map(\.taskID)) == [a.id, other.id])
        let mine = RuntimeWorkspaceReviewWording.folders(try #require(review.holders.first { $0.taskID == a.id }).claims)
        #expect(!mine.isEmpty && !mine.contains("dataset"))
        try start(h, review, b, request)
        func note(_ task: AgentTask) throws -> String {
            try #require(task.events.first { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.hasPrefix("You let other tasks use") }).payload
        }
        #expect(try note(other).contains("`dataset`") && mine.allSatisfy { name in (try? note(other).contains("`\(name)`")) == false })
        #expect(try !note(a).contains("`dataset`") && mine.allSatisfy { name in (try? note(a).contains("`\(name)`")) == true })
    }

    @Test("When one of several holders is still working, the banner names that one and offers no decision", arguments: [0, 1])
    func bannerNamesTheHolderAtWork(working: Int) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h, title: "Export report")
        let (other, _) = try holder(h, title: "Clean data")
        other.workspace = a.workspace
        let busy = [a, other][working]
        busy.runs.first?.status = .running; try h.context.save()
        let (b, request) = try next(h, after: a)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let wanted = queue.resourceLockClaims(for: request, task: b, runMode: "request", sandboxEnforcement: .off)
        let text = queue.resourceBlockerSummary(wanted, modelContext: h.context, request: request, task: b)
        #expect(text.hasPrefix("Waiting for “\(busy.title)” to finish in "), "\(text)")
        #expect(!text.contains("Waiting for you") && !text.contains("start it now"))
        // The dialog agrees: there is nothing to start past yet.
        #expect(try #require(try preview(h, b, request)).canStart == false)
    }

    @Test("A holder whose provider session ASTRA cannot confirm is not promised a new message, and does not get one")
    func stuckHolderIsNotPromisedAWayOn() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h, status: .failed, reason: .capabilitySessionExpired) { record, _ in record.sessionVerificationPending = true }
        let (b, request) = try next(h, after: a)
        let review = try #require(try preview(h, b, request))
        let dialog = RuntimeWorkspaceReviewWording.dialog(review)
        #expect(dialog.canStart && !dialog.message.contains("still works"))
        #expect(dialog.message.contains("ASTRA may refuse a new message in “Export report” too, for the reason above. A new task can carry on that work."))
        try start(h, review, b, request)
        let note = try #require(a.events.first { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.hasPrefix("You let other tasks use") }).payload
        #expect(note.hasSuffix("Retry is not available for that run, and ASTRA may refuse a new message here too, because it cannot confirm that this task's provider session ended. Start a new task to carry on this work."))
        // And that is what admission does.
        let follow = try ExecutionRequestSubmissionService.submitFollowUp(message: "Carry on", for: a, into: h.context).get()
        let message = try #require(try TaskTurnRequestRepository.request(id: follow.requestID, in: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: a, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true, userRequest: message) == nil)
    }

    @Test("The banner on a waiting task names the holder, the folder and the one thing in the way")
    func bannerWording() throws {
        let me = Survivor(process: try Self.alive, name: "python3")
        let more = (0..<4).map { Survivor(process: .init(pid: Int32(200 + $0), startedSeconds: 1, startedMicroseconds: 1), name: "helper\($0)") }
        let jobs = ["11111111-aaaa": RuntimeWorkspaceReviewWording.SSHJob(label: "Nightly export", host: "build-host")]
        func banner(_ blockers: [RuntimeReservationRelease.Blocker], decidable: Bool = true, overlap: String? = nil) -> String {
            RuntimeWorkspaceReviewWording.banner(holder: "Export report", folders: ["reports"], blockers: blockers,
                jobs: jobs, decidable: decidable, overlap: overlap)
        }
        let cases: [([RuntimeReservationRelease.Blocker], String)] = [
            ([.taskWorking, .lostRun], "Waiting for “Export report” to finish in reports."),
            ([], "Waiting for “Export report” to finish in reports."),
            ([.providerAlive(pid: 42)], "Waiting for “Export report” to finish in reports: the provider it started (process 42) is still running."),
            ([.settling], "Waiting for ASTRA to finish closing the last run of “Export report” in reports."),
            ([.survivors([me])], "“Export report” ended but left python3 (process \(me.process.pid)) running in reports. This starts when that stops, or you can start it now."),
            ([.survivors([me]), .survivors(more)], "“Export report” ended but left python3 (process \(me.process.pid)), helper0 (process 200), helper1 (process 201) and 2 more running in reports. This starts when those stop, or you can start it now."),
            ([.sshJobs(["11111111-aaaa"])], "Waiting for you: “Export report” has an SSH job that has not ended: “Nightly export” on build-host."),
            ([.sshJobs(["11111111-aaaa", "22222222-bbbb", "33333333-cccc"])], "Waiting for you: “Export report” has 3 SSH jobs that have not ended: “Nightly export” on build-host, 22222222 and 1 more."),
            ([.container, .lostRun], "Waiting for you: “Export report” ran in a container that ASTRA cannot look inside."),
            ([.settlementUnconfirmed, .lostRun], "Waiting for you: ASTRA lost track of a run of “Export report” and cannot confirm its commands ended."),
            ([.processTableUnreadable], "Waiting for you: ASTRA cannot confirm that “Export report” has stopped using reports.")
        ]
        for (blockers, expected) in cases {
            #expect(banner(blockers) == expected)
            for word in ["cleanup", "receipt", "reservation", "reserved", "verified", "lease", "journal", "claim", "resource"] {
                #expect(!expected.lowercased().contains(word), "\(blockers) says \(word)")
            }
        }
        // A request nobody can decide for is told the same fact, not told to act.
        #expect(banner([.lostRun], decidable: false) == "ASTRA lost track of a run of “Export report” and cannot confirm its commands ended.")
        #expect(banner([.survivors([me])], decidable: false).hasSuffix("This starts when that stops."))
        #expect(banner([.taskWorking], overlap: "it holds /a, which contains /a/reports") == "Waiting for “Export report” to finish in reports. (it holds /a, which contains /a/reports)")
        #expect(RuntimeWorkspaceReviewWording.unreadableBanner(folders: ["reports"]) == "ASTRA cannot read its record of who is using reports. Nothing was started.")
    }

    @Test("The waiting banner is the rule's answer for the holder, asked again only on the pass that asks the rule")
    func bannerOnTheQueue() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try holder(h)
        let (b, request) = try next(h, after: a)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: b, runMode: "request", sandboxEnforcement: .off)
        let wanted = try #require(TaskExecutionResourceBroker.firstConflict(requested: claims, active: queue.activeResourceLocks)).requested
        let place = "\(try #require(RuntimeWorkspaceReviewWording.folders([wanted]).first))"
        func banner() -> String { queue.resourceBlockerSummary(claims, modelContext: h.context, request: request, task: b) }
        // The test workspace sits inside the folder the request names, and the banner says so.
        let held = try #require(TaskExecutionResourceBroker.firstConflict(requested: claims, active: queue.activeResourceLocks)).holder
        let tail = TaskExecutionResourceBroker.containment(holder: held, requested: wanted).map { " (\($0))" } ?? ""
        let lost = "Waiting for you: ASTRA lost track of a run of “Export report” and cannot confirm its commands ended." + tail
        #expect(banner() == lost)
        // Something the saved record does not show changes: the holder is at work again.
        a.runs.first?.status = .running; try h.context.save()
        // The loop asks twice a second. The answer is kept until the pass that asks the rule.
        for _ in 1..<TaskQueue.waitingOwnershipRefreshInterval {
            queue.refreshOwnershipWhileWaiting(blocked: true, in: h.context)
            #expect(banner() == lost)
        }
        queue.refreshOwnershipWhileWaiting(blocked: true, in: h.context)
        #expect(banner() == "Waiting for “Export report” to finish in \(place)." + tail)
        // A full ownership refresh asks again too.
        a.runs.first?.status = .completed; try h.context.save()
        #expect(banner() == "Waiting for “Export report” to finish in \(place)." + tail)
        queue.refreshResourceOwnership(in: h.context)
        #expect(banner() == lost)
        // A request nobody can decide for is not told that it waits for the person.
        request.kind = .scheduled; try h.context.save()
        #expect(banner() == "ASTRA lost track of a run of “Export report” and cannot confirm its commands ended." + tail)
        // A task that waits for its own earlier run is told the fact, not told to act.
        let follow = try ExecutionRequestSubmissionService.submitFollowUp(message: "Carry on", for: a, into: h.context).get()
        let own = try #require(try TaskTurnRequestRepository.request(id: follow.requestID, in: h.context))
        let ownClaims = queue.resourceLockClaims(for: own, task: a, runMode: "request", sandboxEnforcement: .off)
        let ownBanner = queue.resourceBlockerSummary(ownClaims, modelContext: h.context, request: own, task: a)
        #expect(ownBanner.hasPrefix("ASTRA lost track of a run of “Export report” and cannot confirm its commands ended."))
        // When ASTRA cannot read who holds what, it says that and nothing else.
        queue.resourceOwnershipReadFailed = true
        #expect(banner() == "ASTRA cannot read its record of who is using \(place). Nothing was started.")
    }

    @Test("Nothing a person reads uses ASTRA's bookkeeping words, and every answer has a sentence")
    func wording() throws {
        let me = Survivor(process: try Self.alive, name: "python3")
        let other = Survivor(process: .init(pid: 7, startedSeconds: 1, startedMicroseconds: 1), name: "node")
        let record = RuntimeExecutionOwnerRecord(taskID: UUID(), ownerID: UUID(), executionID: UUID(), runID: nil,
            appProcess: Self.dead, providerProcess: Self.dead, runtime: "claude_code", sessionID: nil, state: .finished,
            limits: .init(tokenCeiling: 1, turnsRemaining: 1, secondsRemaining: 1, tokensSpent: 0, costSpent: 0), updatedAt: Date())
        func claim(_ path: String, _ kind: TaskExecutionResourceKind = .workspace) -> TaskResourceLockClaim {
            .init(taskID: record.taskID, resourceKey: path, accessMode: .write, runMode: "previous", resourceKind: kind)
        }
        let unknowns: [RuntimeReservationRelease.Blocker] = [.survivors([me, other]), .sshJobs(["11111111-aaaa", "22222222-bbbb"]),
            .sshJobsUnreadable, .container, .placementUnrecorded, .lostRun, .processTableUnreadable, .settlementUnconfirmed,
            .sessionUnverified, .lineageUnreadable]
        let active: [RuntimeReservationRelease.Blocker] = [.taskWorking, .providerAlive(pid: 42), .settling]
        var sentences = Set<String>()
        for blocker in unknowns + active {
            let holder = RuntimeWorkspaceReview.Holder(taskID: record.taskID, title: "Export report", receipt: record, blockers: [blocker],
                claims: [claim("/tmp/work/reports"), claim("/tmp/work/reports/.git", .gitCommonDirectory)], otherClaims: [claim("/tmp/trees/side")])
            let dialog = RuntimeWorkspaceReviewWording.dialog(.init(requestID: UUID(), holders: [holder]),
                jobs: ["11111111-aaaa": .init(label: "Nightly export", host: "build-host")])
            #expect(dialog.canStart == !blocker.holderIsActive)
            #expect(dialog.title == (blocker.holderIsActive ? "Something is still running in reports" : "Start in reports now?"))
            #expect(dialog.message.contains("“Export report”") && sentences.insert(dialog.message).inserted)
            let text = (dialog.title + " " + dialog.message).lowercased()
            for word in ["cleanup", "receipt", "reservation", "reserved", "verified", "lease", "journal", "claim"] {
                #expect(!text.contains(word), "\(blocker) says \(word)")
            }
            if !blocker.holderIsActive {
                // A holder admission would still refuse is not promised a way on.
                let stuck = blocker == .sessionUnverified || blocker == .lineageUnreadable
                #expect(dialog.message.contains("Starting now also frees side") && dialog.message.contains("Retry is not available in “Export report” for that run."))
                #expect(dialog.message.contains("A new message there still works.") == !stuck)
                #expect(dialog.message.contains("ASTRA may refuse a new message in “Export report” too, for the reason above. A new task can carry on that work.") == stuck)
            }
        }
        let several = RuntimeWorkspaceReviewWording.dialog(.init(requestID: UUID(), holders: [
            .init(taskID: record.taskID, title: "Export report", receipt: record, blockers: [.survivors([me, other])], claims: [claim("/tmp/work/reports")], otherClaims: [])]))
        #expect(several.message.contains("python3 (process \(me.process.pid)) and node (process 7), which it started, are still running. Starting now does not stop them, and they can still change files there."))
        // Processes left by different runs of one holder read as one sentence, and a long list is cut short.
        let many = (0..<9).map { Survivor(process: .init(pid: Int32(100 + $0), startedSeconds: 1, startedMicroseconds: 1), name: "helper\($0)") }
        let merged = RuntimeWorkspaceReviewWording.dialog(.init(requestID: UUID(), holders: [
            .init(taskID: record.taskID, title: "Export report", receipt: record, blockers: [.survivors([me]), .survivors(many)], claims: [claim("/tmp/work/reports")], otherClaims: [])]))
        #expect(merged.message.components(separatedBy: "has ended, but").count == 2)
        #expect(merged.message.contains("python3 (process \(me.process.pid)), helper0 (process 100)") && merged.message.contains("helper4 (process 104) and 4 more, which it started, are still running."))
        #expect(RuntimeWorkspaceReviewWording.folders([claim("/tmp/work/reports/.git", .gitCommonDirectory), claim("/tmp/work/reports"), claim("/tmp/other/.git", .gitCommonDirectory)]) == ["reports", "other"])
        let note = RuntimeWorkspaceReviewWording.holderNote(folders: ["reports"], on: Date(timeIntervalSince1970: 1_795_000_000))
        #expect(note.hasPrefix("You let other tasks use `reports` on ") && note.hasSuffix("Retry is not available for that run. Send a new message here to continue."))
        let unread = RuntimeWorkspaceReviewWording.holderNote(folders: ["reports"], blockers: [.lostRun, .lineageUnreadable])
        #expect(unread.hasSuffix("and ASTRA may refuse a new message here too, because it cannot read this task's earlier runs. Start a new task to carry on this work."))
        let mixed = RuntimeWorkspaceReviewWording.dialog(.init(requestID: UUID(), holders: [
            .init(taskID: UUID(), title: "Export report", receipt: record, blockers: [.lostRun], claims: [claim("/tmp/work/reports")], otherClaims: []),
            .init(taskID: UUID(), title: "Clean data", receipt: record, blockers: [.sessionUnverified], claims: [claim("/tmp/work/reports")], otherClaims: [])]))
        #expect(mixed.message.contains("A new message in “Export report” still works. ASTRA may refuse a new message in “Clean data” too, for the reason above."))
    }
}
