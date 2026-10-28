import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Repairs the old configured-SSH fence only from the protected process receipt.
/// toolsStopped is the runner's complete terminal stream with *no* tools or
/// unknown execution, not a model statement or an empty list of persisted events.
@MainActor
enum RuntimeHostNoToolReceiptReconciliation {
    static func reconciled(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask) -> RuntimeExecutionOwnerRecord? {
        guard saved.taskID == task.id, saved.state == .finished,
              saved.resourcesReleased == false, saved.cancellationRequested != true,
              saved.inheritedToolUncertainty != true, saved.settlementInProgress == false,
              saved.settlementLocalWorkStopped == true, saved.settlementToolsStopped == true,
              let proof = saved.stopProof, !proof.remoteWorkExcluded, proof.toolsStopped,
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
            toolsStopped: proof.toolsStopped, remoteWorkExcluded: true, capturedAt: proof.capturedAt)
        guard result.canReplace else { return nil }
        result.resourcesReleased = true
        result.providerSharedStateReleased = true
        result.updatedAt = Date()
        return result
    }

    /// Admission reconciliation owns both the global admission fence and the
    /// task lease. Live workers, unreadable receipts and uncertain tools stay fenced.
    static func reconcile(in store: RuntimeExecutionOwnerStore, context: ModelContext) throws {
        let candidates = try store.records().filter {
            $0.state == .finished && $0.resourcesReleased == false && $0.stopProof?.remoteWorkExcluded == false
                && $0.stopProof?.toolsStopped == true
        }
        guard !candidates.isEmpty else { return }
        let admission: RuntimeExecutionOwnerStore.Lease
        do { admission = try store.acquireAdmission() }
        catch RuntimeExecutionOwnerStore.Failure.busy { return }
        defer { withExtendedLifetime(admission) {} }
        for candidate in candidates {
            let lease: RuntimeExecutionOwnerStore.Lease
            do { lease = try store.acquire(taskID: candidate.taskID) }
            catch RuntimeExecutionOwnerStore.Failure.busy { continue }
            defer { withExtendedLifetime(lease) {} }
            let taskID = candidate.taskID
            let tasks = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
            guard tasks.count == 1, let task = tasks.first, let saved = try lease.read(),
                  let repaired = reconciled(saved, task: task) else { continue }
            // The journal retains the original proof even if an audit save is
            // interrupted. No task, request, run, usage or output is rewritten.
            try lease.save(repaired)
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(repaired, fallback: "{}"),
                run: task.runs.first { $0.id == repaired.runID }))
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                modelContext: context, taskID: task.id,
                auditFields: ["operation": "reconcile_finished_host_no_tool_receipt"])
        }
    }
}
