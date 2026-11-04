import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// An explicit local check for the exact timed-out host run. Only a new human
/// instruction may use its observation. Checking never submits a request.
@MainActor
enum RuntimeTimeoutRecoveryCheck {
    static func check(task: AgentTask, runID: UUID, context: ModelContext) throws {
        guard task.isLive, task.modelContext === context, !task.isDone,
              let run = task.runs.max(by: { $0.startedAt < $1.startedAt }),
              run.id == runID, run.typedStopReason == .providerRunWallClockExceeded,
              run.status == .failed || run.status == .timeout else {
            throw RuntimeExecutionOwnerStore.Failure.busy
        }
        let admission = try RuntimeExecutionOwner.store(in: context).acquireAdmission()
        defer { withExtendedLifetime(admission) {} }
        let lease = try RuntimeTaskOwnerJournal.acquire(task: task, context: context)
        defer { withExtendedLifetime(lease) {} }
        guard var record = try lease.read(), record.taskOwnerID == task.persistentModelID,
              record.runID == runID, record.state == .unverified, record.resourcesReleased == false,
              record.cancellationRequested != true,
              var proof = record.stopProof, proof.executionID == record.executionID,
              proof.process == record.providerProcess, proof.reaped, !proof.processGroupEmpty,
              proof.process.processAndGroupAreAbsent else {
            throw RuntimeExecutionOwnerStore.Failure.busy
        }
        let alreadyObserved = proof.groupObservedEmptyAt != nil
        proof.groupObservedEmptyAt = proof.groupObservedEmptyAt ?? Date()
        record.stopProof = proof
        guard RuntimeCompletedUserTurnContinuation.hasSettledTurn(record, task: task, context: context) else {
            throw RuntimeExecutionOwnerStore.Failure.busy
        }
        try RuntimeWorkspaceContinuation.requireNoKnownRemoteWork(task: task, context: context)
        if !alreadyObserved {
            record.updatedAt = Date()
            try lease.save(record)
        }
        // A crash after the protected write can leave the timeline one save behind.
        let type = TaskEventTypes.System.runtimeExecutionOwnership
        if !alreadyObserved || !TaskEventTypeLookup.events(ofType: type.rawValue, task: task, run: run).contains(where: {
            (try? JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: Data($0.payload.utf8))) == record
        }) {
            context.insert(TaskEvent(task: task, eventType: type, payload: TaskEvent.payloadString(record, fallback: "{}"), run: run))
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
                payload: "The timed-out provider and its local process group have stopped. You can continue this task with a new message. Earlier tool activity remains unverified.", run: run))
        }
        if context.hasChanges {
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace, modelContext: context,
                taskID: task.id, auditFields: ["operation": "recheck_timed_out_process_group"])
        }
    }
}

extension TaskQueue {
    @MainActor
    func recheckTimedOutRun(_ runID: UUID, task: AgentTask, context: ModelContext) {
        do {
            try RuntimeTimeoutRecoveryCheck.check(task: task, runID: runID, context: context)
            if let request = try TaskTurnRequestRepository.activeRequests(for: task, in: context).first,
               RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: context) {
                _ = signalExecutionRequest(id: request.id, task: task, modelContext: context)
            }
        } catch {
            RuntimeExecutionOwner.report("ASTRA could not verify cleanup of the timed-out run. Check its local processes and remote jobs before trying again.",
                task: task, context: context, autoExport: false)
        }
    }
}
