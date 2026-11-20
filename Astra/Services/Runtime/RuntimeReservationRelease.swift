import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Why a reservation ended, saved with the release. It is evidence for a
/// person reading the journal; nothing reads the basis back to decide anything.
struct RuntimeReservationReleaseRecord: Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable {
        /// The exit record already showed nothing was left.
        case exitProof = "exit_proof"
        /// The process table, asked after the exit, showed nothing from the launch alive.
        case processTable = "process_table"
        /// Every execution of the owner ended before this Mac's current boot.
        case hostRestart = "host_restart"
    }
    let basis: Basis
    var bootedAt: Date? = nil
}

/// A reservation keeps two live writers out of one folder. It ends when
/// nothing its owner started can still act, and that is a question about
/// now: the process table, this boot, the SSH job inventory. The outcome of
/// the work is not part of the answer, because a process that failed is as
/// gone as one that succeeded.
///
/// A workspace that offers an SSH route does not keep a reservation by
/// itself. The reservation protects a folder on this Mac, which only a
/// process on this Mac can change, and the local facts cover that: a local
/// `ssh` still running is a survivor like any other. What stays held is an
/// SSH job ASTRA tracks that has not ended.
///
/// This is the one place that decides a saved reservation has ended
/// (`RuntimeExecutionOwner.finish()` asks the same question at exit through
/// `canReplace`). Retry and recovery do not read it: they keep `canReplace`,
/// which a release granted here does not change.
///
/// Design: docs/specs/2026-11-18-workspace-reservation-and-parallelism.md, A.
@MainActor
enum RuntimeReservationRelease {
    /// One fact that keeps a reservation. `isRunning` facts are observed on
    /// this Mac now; every other fact is something ASTRA cannot observe.
    enum Blocker: Equatable, Sendable {
        case taskWorking
        case providerAlive(pid: Int32)
        case survivors([RuntimeLocalSurvivorObservation.Survivor])
        case settling
        /// SSH jobs of the owner that have not ended, by job ID.
        case sshJobs([String])
        /// The owner's job records cannot be read, or they are not the jobs
        /// its receipt recorded at exit.
        case sshJobsUnreadable
        case container
        case placementUnrecorded
        /// No exit record or scope value to ask about, and no restart since.
        case lostRun
        case processTableUnreadable
        case settlementUnconfirmed
        case sessionUnverified
        case lineageUnreadable

        var isRunning: Bool {
            switch self {
            case .taskWorking, .providerAlive, .survivors, .settling: true
            default: false
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case release(RuntimeReservationReleaseRecord.Basis)
        case held([Blocker])
    }

    /// The stop proof, when it is the one written for this execution's process.
    nonisolated private static func proof(of execution: RuntimeExecutionOwnerRecord) -> RuntimeExecutionStopProof? {
        guard let proof = execution.stopProof, proof.executionID == execution.executionID,
              proof.process == execution.providerProcess else { return nil }
        return proof
    }

    /// An attempt that never reached a provider launch. An older receipt has
    /// no launch count, so there only an attempt that never bound a run counts.
    nonisolated private static func neverLaunched(_ execution: RuntimeExecutionOwnerRecord) -> Bool {
        (execution.state == .notStarted || execution.state == .preparing)
            && execution.providerProcess == nil && execution.stopProof == nil
            && (execution.providerLaunchCount == 0 || execution.runID == nil)
    }

    /// True when the receipt alone already holds the reservation, so no task
    /// fetch, journal, lineage or process-table read can change the answer.
    /// Every held receipt is asked this on every ownership refresh.
    nonisolated static func heldByReceiptAlone(_ saved: RuntimeExecutionOwnerRecord) -> Bool {
        if saved.sessionVerificationPending == true { return true }
        if let process = saved.providerProcess, process.presence == .present { return true }
        return false
    }

    /// The exact jobs a receipt recorded at exit were withdrawn before any
    /// of them started. Retry's stop-proof upgrade needs this; the
    /// reservation only needs them ended.
    private static func sshJobsWithdrawn(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask, context: ModelContext) -> Bool {
        guard let expected = saved.pendingSSHJobSetDigest,
              let evidence = try? RuntimeWorkspaceRemoteJobs.releaseEvidence(task: task, owner: saved, context: context) else { return false }
        return evidence.safe && evidence.identity == expected
    }

    /// The whole rule, for the receipt and every execution retained in its
    /// lineage. `journal` is the receipt's own file: its change time is the
    /// kernel's statement of when the receipt was last written.
    static func verdict(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask, journal: URL,
                        store: RuntimeExecutionOwnerStore, context: ModelContext, bootedAt: Date?,
                        observe: (RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation
                            = { RuntimeExecutionLocalSurvivors.observe($0) }) -> Verdict {
        var blockers: [Blocker] = []
        func hold(_ blocker: Blocker) { if !blockers.contains(blocker) { blockers.append(blocker) } }
        if task.runs.contains(where: { $0.status == .running }) { hold(.taskWorking) }
        if saved.sessionVerificationPending == true { hold(.sessionUnverified) }
        let journalPredatesBoot = bootedAt.map { ProviderSharedStateReadObservation.journalPredatesBoot(journal, bootedAt: $0) } ?? false
        let runs = Dictionary(grouping: task.runs, by: \.id)
        var askedProcessTable = false
        var answeredByRestart = false
        var asked: Set<String> = []

        // Set when an execution's receipt recorded SSH jobs at its exit.
        var recordedSSHJobs = false

        func ask(_ execution: RuntimeExecutionOwnerRecord) {
            asked.insert(execution.executionID.uuidString)
            let proof = proof(of: execution)
            let supervisorGone = execution.appProcess.presence == .absent
            let ended = proof?.capturedAt ?? execution.updatedAt
            // Nothing on this Mac outlives a restart: the receipt, its exit
            // and the ASTRA process that supervised it all predate this boot.
            let beforeBoot = journalPredatesBoot && supervisorGone && (bootedAt.map { ended < $0 } ?? false)

            if execution.settlementInProgress == true || execution.settlementLocalWorkStopped == false
                || execution.settlementToolsStopped == false {
                if beforeBoot { answeredByRestart = true }
                else { hold(execution.settlementInProgress == true && !supervisorGone ? .settling : .settlementUnconfirmed) }
            }
            if execution.pendingSSHJobSetDigest != nil { recordedSSHJobs = true }
            guard !neverLaunched(execution) else { return }

            // Where it ran. A container keeps its own process table.
            if let id = execution.runID, let matches = runs[id], matches.count == 1, let run = matches.first,
               run.runtimeID == execution.runtime, let json = run.executionEnvironmentSnapshotJSON,
               let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(json.utf8)) {
                if !environment.isHost { hold(.container) }
            } else { hold(.placementUnrecorded) }

            if let process = execution.providerProcess {
                switch process.presence {
                case .present: hold(.providerAlive(pid: process.pid)); return
                case .unknown: if !beforeBoot { hold(.lostRun); return }
                case .absent: break
                }
            }
            guard let proof else {
                // No exit record: the attempt was labelled not started after a
                // provider did launch, or ASTRA lost the run. Whatever it started
                // on this Mac ran before the boot, or there is nothing to ask the
                // process table about.
                if beforeBoot { answeredByRestart = true } else { hold(.lostRun) }
                return
            }
            if beforeBoot { answeredByRestart = true; return }
            guard proof.reaped, proof.processGroupEmpty else { hold(.lostRun); return }
            // The transcript shows no tool ran, or the only tool was ASTRA's SSH
            // helper, which starts nothing here that outlives the launch; its
            // jobs are asked about below.
            if proof.toolsStopped || proof.managedSSHOnly == true { return }
            guard let earlier = proof.localSurvivors else { hold(.lostRun); return }
            // A recorded survivor that is still there answers without a scan.
            let alive = earlier.survivors.filter { $0.process.presence != .absent }
            if !alive.isEmpty { hold(.survivors(alive)); return }
            let now = observe(earlier.launch)
            if !now.complete { hold(.processTableUnreadable) }
            else if !now.survivors.isEmpty { hold(.survivors(now.survivors)) }
            else { askedProcessTable = true }
        }

        ask(saved)
        // When the receipt's own facts hold it, no earlier execution can end it.
        guard blockers.isEmpty else { return .held(blockers) }
        guard let retained = try? store.retainedExecutions(of: saved) else { return .held([.lineageUnreadable]) }
        // A release is final: an execution whose reservation already ended is not asked again.
        for execution in retained where execution.resourcesReleased != true { ask(execution) }
        // A tracked SSH job that has not ended keeps the reservation. So does a
        // job record that cannot be read. Where a receipt recorded its jobs at
        // exit, the set found now must be that set: a missing or replaced
        // record is not an ended job.
        if recordedSSHJobs || !ProviderSharedStateReadObservation.noRemoteRegistrations(for: saved.taskID, store: store) {
            let jobs = try? RuntimeWorkspaceRemoteJobs.inventory(task: task, owner: saved, context: context)
            let found: Bool
            if let expected = saved.pendingSSHJobSetDigest {
                found = (try? RuntimeWorkspaceRemoteJobs.releaseEvidence(task: task, owner: saved, context: context))?.identity == expected
            } else { found = !recordedSSHJobs || jobs?.isEmpty == false }
            if let jobs, found {
                let open = jobs.filter { !$0.status.isTerminal && asked.contains($0.executionID) }.map(\.jobID)
                if !open.isEmpty { hold(.sshJobs(open.sorted())) }
            } else { hold(.sshJobsUnreadable) }
        }
        guard blockers.isEmpty else { return .held(blockers) }
        return .release(answeredByRestart ? .hostRestart : askedProcessTable ? .processTable : .exitProof)
    }

    /// Asks the rule for every saved reservation and releases those that
    /// pass. It holds the admission fence and the task lease; a live worker,
    /// a changed receipt and an unreadable one are skipped and asked again on
    /// the next refresh. No task, request, run, usage or output is rewritten.
    /// Returns how many reservations it ended.
    @discardableResult
    static func reconcile(in store: RuntimeExecutionOwnerStore, context: ModelContext,
                          bootedAt: Date? = ProviderSharedStateReadObservation.hostBootTime(),
                          observe: (RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation
                              = { RuntimeExecutionLocalSurvivors.observe($0) }) throws -> Int {
        let candidates = try store.records().filter {
            RuntimeResourceOwnership.retainsResources($0) && $0.resourceClaims != nil && !heldByReceiptAlone($0)
        }
        guard !candidates.isEmpty else { return 0 }
        let admission: RuntimeExecutionOwnerStore.Lease
        do { admission = try store.acquireAdmission() }
        catch RuntimeExecutionOwnerStore.Failure.busy { return 0 }
        defer { withExtendedLifetime(admission) {} }
        var ended = 0
        for candidate in candidates {
            let lease: RuntimeExecutionOwnerStore.Lease
            let legacy = try store.read(taskID: candidate.taskID) == candidate
            do { lease = try store.acquire(taskID: candidate.taskID, taskOwnerID: legacy ? nil : candidate.taskOwnerID) }
            catch RuntimeExecutionOwnerStore.Failure.busy { continue }
            defer { withExtendedLifetime(lease) {} }
            let taskID = candidate.taskID
            let tasks = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
            let matching = tasks.filter { candidate.taskOwnerID == nil || $0.persistentModelID == candidate.taskOwnerID }
            guard matching.count == 1, let task = matching.first, let saved = try lease.read(), saved == candidate else { continue }
            // One process-table answer per launch per pass, shared with the proof upgrade below.
            var observations: [String: RuntimeLocalSurvivorObservation] = [:]
            func observeOnce(_ launch: RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation {
                if let known = observations[launch.scope] { return known }
                let value = observe(launch)
                observations[launch.scope] = value
                return value
            }
            guard case .release(let basis) = verdict(saved, task: task, journal: lease.recordURL, store: store,
                context: context, bootedAt: bootedAt, observe: observeOnce) else { continue }
            var released = saved
            // Jobs that ended end the reservation. Only the exact recorded jobs,
            // withdrawn before any started, also settle the saved inventory,
            // which is what Retry's stop-proof upgrade below asks for.
            let settledSSHInventory = sshJobsWithdrawn(saved, task: task, context: context)
            if settledSSHInventory { released.pendingSSHJobSetDigest = nil }
            // Where today's rules also upgrade the stop proof they still do,
            // under their own unchanged conditions: Retry reads that upgrade.
            var operation = settledSSHInventory ? "release_after_ssh_cancellation" : "release_reservation"
            if !settledSSHInventory, let restarted = try RuntimeHostRestartRelease.released(
                released, task: task, journal: lease.recordURL, store: store, bootedAt: bootedAt) {
                released = restarted; operation = "release_after_host_restart"
            } else if RuntimeHostNoToolReceiptReconciliation.awaitsLocalSurvivors(saved),
                      let reobserved = RuntimeHostNoToolReceiptReconciliation.reobserved(released, observe: observeOnce) {
                released = reobserved; operation = "release_after_local_survivors_exited"
            } else if let reconciled = RuntimeHostNoToolReceiptReconciliation.reconciled(
                released, task: task, managedSSHJobsVerified: settledSSHInventory) {
                released = reconciled
                if !settledSSHInventory { operation = "reconcile_finished_host_no_tool_receipt" }
            }
            released.resourcesReleased = true
            released.providerSharedStateReleased = true
            released.reservationRelease = .init(basis: basis, bootedAt: basis == .hostRestart ? bootedAt : nil)
            released.updatedAt = Date()
            // The journal keeps the original receipt's digest even if the audit save is interrupted.
            released = try lease.saveReconciliation(from: saved, to: released)
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(released, fallback: "{}"),
                run: task.runs.first { $0.id == released.runID }))
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                modelContext: context, taskID: task.id,
                auditFields: ["operation": operation, "basis": basis.rawValue])
            ended += 1
        }
        return ended
    }
}
