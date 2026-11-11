import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Repairs configured-SSH fences from protected process and job evidence.
/// Native helper frames remain uncertain until their exact broker-accounted job
/// inventory proves permission was withdrawn before dispatch. Unrelated tools
/// and unknown execution are never promoted by a model statement or host scan.
@MainActor
enum RuntimeHostNoToolReceiptReconciliation {
    static func reconciled(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask, managedSSHJobsVerified: Bool = false) -> RuntimeExecutionOwnerRecord? {
        guard saved.taskID == task.id, saved.state == .finished,
              saved.resourcesReleased == false, saved.cancellationRequested != true,
              saved.inheritedToolUncertainty != true, saved.settlementInProgress == false,
              saved.settlementLocalWorkStopped == true, saved.settlementToolsStopped == true,
              let proof = saved.stopProof, !proof.remoteWorkExcluded || !proof.toolsStopped,
              proof.toolsStopped || (managedSSHJobsVerified && proof.managedSSHOnly == true),
              proof.reaped, proof.processGroupEmpty, proof.executionID == saved.executionID,
              proof.process == saved.providerProcess, proof.process.presence == .absent,
              let runID = saved.runID, let run = task.runs.first(where: { $0.id == runID }),
              task.runs.max(by: { $0.startedAt < $1.startedAt })?.id == runID,
              !task.runs.contains(where: { $0.status == .running }),
              run.status == .completed, run.typedStopReason == .completed, run.completedAt != nil,
              let snapshot = run.executionEnvironmentSnapshotJSON,
              let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(snapshot.utf8)),
              environment.isHost else { return nil }
        var result = saved
        result.hostNoToolReconciliationOriginalProof = proof
        result.stopProof = .init(executionID: proof.executionID, process: proof.process,
            reaped: proof.reaped, processGroupEmpty: proof.processGroupEmpty,
            toolsStopped: true, remoteWorkExcluded: true, capturedAt: proof.capturedAt, managedSSHOnly: proof.managedSSHOnly)
        guard result.canReplace else { return nil }
        result.resourcesReleased = true
        result.providerSharedStateReleased = true
        result.updatedAt = Date()
        return result
    }

    /// A receipt that recorded live local survivors is asked again once those
    /// processes are gone. The process table answers; no statement or decision does.
    static func reobserved(_ saved: RuntimeExecutionOwnerRecord,
                           observe: (RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation = { RuntimeExecutionLocalSurvivors.observe($0) }) -> RuntimeExecutionOwnerRecord? {
        guard awaitsLocalSurvivors(saved), saved.cancellationRequested != true, saved.inheritedToolUncertainty != true,
              saved.settlementInProgress == false, saved.settlementLocalWorkStopped == true, saved.settlementToolsStopped == true,
              let proof = saved.stopProof, let earlier = proof.localSurvivors, proof.remoteWorkExcluded,
              proof.executionID == saved.executionID, proof.process == saved.providerProcess, proof.process.presence == .absent,
              earlier.launch.provider == proof.process,
              earlier.survivors.allSatisfy({ $0.process.presence == .absent }) else { return nil }
        let current = observe(earlier.launch)
        guard current.clean else { return nil }
        var result = saved
        result.hostNoToolReconciliationOriginalProof = proof
        result.stopProof = proof.observing(current)
        guard result.canReplace else { return nil }
        result.resourcesReleased = true
        result.providerSharedStateReleased = true
        result.updatedAt = Date()
        return result
    }

    nonisolated static func awaitsLocalSurvivors(_ record: RuntimeExecutionOwnerRecord) -> Bool {
        record.state == .finished && record.resourcesReleased == false && record.stopProof?.toolsStopped == false
            && record.stopProof?.localSurvivors?.survivors.isEmpty == false
    }

    /// Admission reconciliation owns both the global admission fence and the
    /// task lease. Live workers, unreadable receipts and uncertain tools stay fenced.
    static func reconcile(in store: RuntimeExecutionOwnerStore, context: ModelContext,
                          bootedAt: Date? = ProviderSharedStateReadObservation.hostBootTime()) throws {
        let candidates = try store.records().filter {
            RuntimeHostRestartRelease.awaits($0, bootedAt: bootedAt) || awaitsLocalSurvivors($0) || ($0.state == .finished && $0.resourcesReleased == false
                && ($0.stopProof?.toolsStopped == true || $0.stopProof?.managedSSHOnly == true)
                && ($0.stopProof?.remoteWorkExcluded == false || $0.pendingSSHJobSetDigest != nil))
        }
        guard !candidates.isEmpty else { return }
        let admission: RuntimeExecutionOwnerStore.Lease
        do { admission = try store.acquireAdmission() }
        catch RuntimeExecutionOwnerStore.Failure.busy { return }
        defer { withExtendedLifetime(admission) {} }
        for candidate in candidates {
            let lease: RuntimeExecutionOwnerStore.Lease
            let legacy = try store.read(taskID: candidate.taskID) == candidate
            do { lease = try store.acquire(taskID: candidate.taskID, taskOwnerID: legacy ? nil : candidate.taskOwnerID) }
            catch RuntimeExecutionOwnerStore.Failure.busy { continue }
            defer { withExtendedLifetime(lease) {} }
            let taskID = candidate.taskID
            let tasks = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
            let matching = tasks.filter { candidate.taskOwnerID == nil || $0.persistentModelID == candidate.taskOwnerID }
            guard matching.count == 1, let task = matching.first, let saved = try lease.read(), saved == candidate,
                  let jobs = try? RuntimeWorkspaceRemoteJobs.releaseEvidence(task: task, owner: saved, context: context),
                  jobs.safe else { continue }
            var repaired = saved
            if let expected = saved.pendingSSHJobSetDigest {
                guard expected == jobs.identity,
                      RuntimeCompletedUserTurnContinuation.hasCompletedTurn(saved, task: task, context: context) else { continue }
                repaired.pendingSSHJobSetDigest = nil
            }
            // A saved SSH inventory is settled by its own evidence, never by a restart.
            let restarted = saved.pendingSSHJobSetDigest != nil ? nil : try RuntimeHostRestartRelease.released(
                repaired, task: task, journal: lease.recordURL, store: store, bootedAt: bootedAt)
            if let restarted {
                repaired = restarted
            } else if awaitsLocalSurvivors(saved) {
                guard let value = reobserved(repaired) else { continue }
                repaired = value
            } else if saved.stopProof?.remoteWorkExcluded == false || saved.stopProof?.toolsStopped == false {
                guard let value = reconciled(repaired, task: task,
                    managedSSHJobsVerified: saved.pendingSSHJobSetDigest != nil && jobs.identity != nil) else { continue }
                repaired = value
            } else {
                guard repaired.canReplace else { continue }
                repaired.resourcesReleased = true
                repaired.providerSharedStateReleased = true
                repaired.updatedAt = Date()
            }
            // The journal retains the original proof even if an audit save is
            // interrupted. No task, request, run, usage or output is rewritten.
            repaired = try lease.saveReconciliation(from: saved, to: repaired)
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(repaired, fallback: "{}"),
                run: task.runs.first { $0.id == repaired.runID }))
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                modelContext: context, taskID: task.id,
                auditFields: ["operation": restarted != nil ? "release_after_host_restart"
                    : awaitsLocalSurvivors(saved) ? "release_after_local_survivors_exited"
                    : (saved.pendingSSHJobSetDigest == nil ? "reconcile_finished_host_no_tool_receipt" : "release_after_ssh_cancellation")])
        }
    }
}
