import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Admission for a newly authored human instruction within the SAME logical
/// owner. This never certifies tool cleanup, releases a reservation, or permits
/// automatic replay. Uncertain earlier effects remain owned and recorded.
@MainActor
enum RuntimeCompletedUserTurnContinuation {
    static func permits(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                        request: TaskTurnRequest?, context: ModelContext) -> Bool {
        guard task.isLive, task.modelContext === context,
              let request, request.modelContext === context, request.state.isActive,
              request.taskID == task.id else { return false }
        if RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction,
           hasCompletedTurn(saved, task: task, context: context) { return true }
        guard hasUnlaunchedPreparation(saved, task: task, context: context),
              request.kind == .followUp,
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task),
              source.type == TaskEventTypes.Conversation.userMessage.rawValue else { return false }
        if saved.continuingUserRequestID == request.id {
            // A source linked during preflight is not consumed by a provider
            // when the durable launch-intent boundary was never crossed.
            return (source.run == nil || source.run?.id == saved.runID)
                && (request.runID == nil || request.runID == saved.runID)
                && (request.startedAt == nil || (saved.runID != nil && request.runID == saved.runID))
        }
        // A different message must not silently supersede accepted unsent work.
        guard let previousID = saved.continuingUserRequestID,
              let previous = try? TaskTurnRequestRepository.request(id: previousID, in: context),
              !previous.state.isActive else { return false }
        return RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction
    }

    static func hasCompletedTurn(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                 context: ModelContext) -> Bool {
        completedBasis(saved, task: task, context: context, excluding: [])
    }

    static func hasUnlaunchedPreparation(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                        context: ModelContext) -> Bool {
        guard unlaunched(saved), let history = try? RuntimeExecutionOwner.store(in: context).retainedExecutions(of: saved),
              let completedIndex = history.firstIndex(where: { completedState($0) }) else { return false }
        let preparations = [saved] + Array(history.prefix(completedIndex))
        guard preparations.allSatisfy(unlaunched) else { return false }
        let ignored = Set(preparations.compactMap(\.runID))
        return completedBasis(history[completedIndex], task: task, context: context, excluding: ignored)
    }

    private static func completedState(_ saved: RuntimeExecutionOwnerRecord) -> Bool {
        // Settlement may have committed before finish() persisted .finished.
        // All run, barrier and process evidence is checked separately below.
        saved.state == .finished || saved.state == .stopped || saved.state == .unverified
    }

    private static func unlaunched(_ saved: RuntimeExecutionOwnerRecord) -> Bool {
        (saved.state == .preparing || saved.state == .notStarted)
            && saved.continuingUserRequestID != nil && saved.retainedExecutionHead != nil
            && saved.providerProcess == nil && saved.stopProof == nil
            && saved.cancellationRequested != true && saved.settlementInProgress != true
            && saved.settlementLocalWorkStopped != false && saved.settlementToolsStopped != false
    }

    private static func completedBasis(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                       context: ModelContext, excluding ignored: Set<UUID>) -> Bool {
        guard task.isLive, task.modelContext === context,
              saved.taskID == task.id, completedState(saved),
              saved.cancellationRequested != true,
              saved.settlementInProgress == false, saved.settlementLocalWorkStopped == true,
              saved.settlementToolsStopped == true,
              saved.resourceClaims != nil,
              let proof = saved.stopProof, proof.executionID == saved.executionID,
              proof.process == saved.providerProcess, proof.reaped, proof.processGroupEmpty,
              proof.process.presence == .absent,
              let runID = saved.runID, let run = task.runs.first(where: { $0.id == runID }),
              run.status == .completed, run.typedStopReason == .completed, run.completedAt != nil,
              task.runs.filter({ !ignored.contains($0.id) }).max(by: { $0.startedAt < $1.startedAt })?.id == runID,
              !task.runs.contains(where: { $0.status == .running && !ignored.contains($0.id) }),
              let snapshot = run.executionEnvironmentSnapshotJSON,
              let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(snapshot.utf8)),
              environment.isHost else { return false }
        // Imported event JSON cannot authorize a continuation. Every retained
        // receipt must still be readable from the protected journal.
        return (try? RuntimeExecutionOwner.store(in: context).retainedExecutions(of: saved)) != nil
    }

    static func permits(task: AgentTask, request: TaskTurnRequest?, context: ModelContext) -> Bool {
        guard let saved = try? RuntimeExecutionOwner.existing(task: task, context: context) else { return false }
        return permits(saved, task: task, request: request, context: context)
    }

    static func retainingClaims(_ prior: RuntimeExecutionOwnerRecord,
                                additional: [TaskResourceLockClaim], requestID: UUID?) -> [TaskResourceLockClaim] {
        let claims = ((prior.resourceClaims ?? []) + additional).map {
            TaskExecutionResourceClaim(kind: $0.resourceKind, key: $0.resourceKey,
                access: $0.accessMode == .write ? .exclusive : .shared)
        }
        return TaskExecutionResourceBroker.lockClaims(for: claims, taskID: prior.taskID,
            requestID: requestID, runMode: "user_continuation")
    }
}
