import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Admission after a settled turn for a newly authored human instruction within the SAME logical
/// owner. This never certifies tool cleanup, releases a reservation, or permits
/// automatic replay. Uncertain earlier effects remain owned and recorded.
@MainActor
enum RuntimeCompletedUserTurnContinuation {
    static func permits(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                        request: TaskTurnRequest?, context: ModelContext) -> Bool {
        guard saved.sessionVerificationPending != true, task.isLive, task.modelContext === context,
              let request, request.modelContext === context, request.state.isActive,
              request.taskID == task.id else { return false }
        if RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction,
           hasSettledTurn(saved, task: task, context: context) { return true }
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
        settledBasis(saved, task: task, context: context, excluding: [], requiresSuccess: true)
    }

    /// Failure ends the provider turn without certifying completion of the
    /// user's work. A new human message can continue the same reserved owner
    /// once local execution and settlement have ended. Automatic recovery and
    /// other tasks still need their original, stronger cleanup proof.
    static func hasSettledTurn(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                               context: ModelContext) -> Bool {
        settledBasis(saved, task: task, context: context, excluding: [], requiresSuccess: false)
    }

    static func hasUnlaunchedPreparation(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                        context: ModelContext) -> Bool {
        guard unlaunched(saved, task: task, context: context), let history = try? RuntimeExecutionOwner.store(in: context).retainedExecutions(of: saved),
              let settledIndex = history.firstIndex(where: { settledState($0) }) else { return false }
        let preparations = [saved] + Array(history.prefix(settledIndex))
        guard preparations.allSatisfy({ unlaunched($0, task: task, context: context) }) else { return false }
        let ignored = Set(preparations.compactMap(\.runID))
        return settledBasis(history[settledIndex], task: task, context: context, excluding: ignored, requiresSuccess: false)
    }

    private static func settledState(_ saved: RuntimeExecutionOwnerRecord) -> Bool {
        // Settlement may have committed before finish() persisted .finished.
        // All run, barrier and process evidence is checked separately below.
        saved.state == .finished || saved.state == .stopped || saved.state == .unverified
    }

    private static func unlaunched(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                   context: ModelContext) -> Bool {
        guard (saved.state == .preparing || saved.state == .notStarted)
            && saved.continuingUserRequestID != nil && saved.retainedExecutionHead != nil
            && saved.providerProcess == nil && saved.stopProof == nil
            && saved.settlementInProgress != true && saved.settlementLocalWorkStopped != false
            && saved.settlementToolsStopped != false else { return false }
        guard saved.cancellationRequested == true else { return true }
        // Stop before the launch-intent boundary cancels this attempt, not
        // its predecessor's authorization for a separately authored message.
        // Require the durable cancellation and joined settlement, never just
        // an absent PID (which is also possible after a failed launch).
        guard saved.state == .notStarted, saved.settlementInProgress == false,
              saved.settlementLocalWorkStopped == true, saved.settlementToolsStopped == true else { return false }
        if saved.runID != nil { return cancelledAttempt(saved, task: task, context: context) }
        // Preparation can end before a TaskRun exists. Its protected request
        // identity and untouched human source are the evidence in that case.
        guard let requestID = saved.continuingUserRequestID,
              let request = try? TaskTurnRequestRepository.request(id: requestID, in: context),
              (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID,
              request.kind == .followUp, request.state == .cancelled,
              request.runID == nil, request.startedAt == nil,
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task),
              source.type == TaskEventTypes.Conversation.userMessage.rawValue, source.run == nil else { return false }
        return true
    }

    private static func cancelledAttempt(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                         context: ModelContext) -> Bool {
        guard saved.cancellationRequested == true, let runID = saved.runID,
              let request = try? TaskTurnRequestRepository.origin(for: task, runID: runID, in: context),
              saved.continuingUserRequestID == nil || saved.continuingUserRequestID == request.id,
              request.taskID == task.id, request.state == .cancelled,
              request.runID == runID,
              let run = task.runs.first(where: { $0.id == runID }),
              run.status == .cancelled, run.typedStopReason == .cancelled,
              run.completedAt != nil else { return false }
        return true
    }

    private static func settledBasis(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                     context: ModelContext, excluding ignored: Set<UUID>, requiresSuccess: Bool) -> Bool {
        guard saved.sessionVerificationPending != true, task.isLive, task.modelContext === context,
              saved.taskID == task.id, settledState(saved),
              saved.cancellationRequested != true || cancelledAttempt(saved, task: task, context: context),
              saved.settlementInProgress == false, saved.settlementLocalWorkStopped == true,
              saved.settlementToolsStopped == true,
              saved.resourceClaims != nil,
              let proof = saved.stopProof, proof.executionID == saved.executionID,
              proof.process == saved.providerProcess, proof.reaped, proof.processGroupEmpty,
              proof.process.presence == .absent,
              let runID = saved.runID, let run = task.runs.first(where: { $0.id == runID }),
              settledOutcome(run, requiresSuccess: requiresSuccess,
                cancelled: cancelledAttempt(saved, task: task, context: context)), run.completedAt != nil,
              task.runs.filter({ !ignored.contains($0.id) }).max(by: { $0.startedAt < $1.startedAt })?.id == runID,
              !task.runs.contains(where: { $0.status == .running && !ignored.contains($0.id) }),
              let snapshot = run.executionEnvironmentSnapshotJSON,
              let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(snapshot.utf8)),
              environment.isHost else { return false }
        // Imported event JSON cannot authorize a continuation. Every retained
        // receipt must still be readable from the protected journal.
        return (try? RuntimeExecutionOwner.store(in: context).retainedExecutions(of: saved)) != nil
    }

    private static func settledOutcome(_ run: TaskRun, requiresSuccess: Bool, cancelled: Bool) -> Bool {
        if run.status == .completed { return run.typedStopReason == .completed }
        if !requiresSuccess, run.status == .cancelled { return cancelled }
        guard !requiresSuccess, let reason = run.typedStopReason,
              reason != .completed, reason != .cancelled else { return false }
        switch run.status {
        case .failed, .timeout, .budgetExceeded: return true
        case .running, .completed, .cancelled: return false
        }
    }

    static func permits(task: AgentTask, request: TaskTurnRequest?, context: ModelContext) -> Bool {
        guard let saved = try? RuntimeExecutionOwner.existing(task: task, context: context) else { return false }
        return permits(saved, task: task, request: request, context: context)
    }

    static func retainingClaims(_ prior: RuntimeExecutionOwnerRecord,
                                additional: [TaskResourceLockClaim], requestID: UUID?) -> [TaskResourceLockClaim] {
        // Admission archives the predecessor before saving this successor.
        // Session protection is projected from that chain; copying its sessions
        // into every successor would eventually make the receipt unreadable.
        let inherited = (prior.resourceClaims ?? []).filter { $0.resourceKind != .nativeSession }
        let claims = (inherited + additional).map {
            TaskExecutionResourceClaim(kind: $0.resourceKind, key: $0.resourceKey,
                access: $0.accessMode == .write ? .exclusive : .shared)
        }
        return TaskExecutionResourceBroker.lockClaims(for: claims, taskID: prior.taskID,
            requestID: requestID, runMode: "user_continuation")
    }
}
