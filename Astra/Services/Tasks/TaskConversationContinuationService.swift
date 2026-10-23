import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The main-actor half of pressing Enter on a task that already ran: persist
/// the turn, retire any run it supersedes, record the composer's policy level
/// when it changed, and wake the queue. Everything after this — admission, the
/// worker, the provider — is asynchronous.
///
/// It lives here rather than in `TaskMainView` so the send can be measured on
/// its own: `TaskMainActorScalingGateTests` holds the entire operation to an interactive
/// budget on disk-backed long histories.
@MainActor
enum TaskConversationContinuationService {
    struct Continuation: Equatable {
        let requestID: UUID
        let runsInterrupted: Int
    }

    static func continueConversation(
        message: String,
        attachmentPaths: [String],
        task: AgentTask,
        policyLevel: AgentPolicyLevel,
        source: String,
        traceID: String,
        taskQueue: TaskQueue,
        modelContext: ModelContext
    ) -> Result<Continuation, TaskTurnSubmissionService.SubmissionError> {
        // Persist the user's turn before waiting for a worker or the
        // workspace lock. The runtime links this existing event to its run
        // on admission instead of inserting a duplicate message.
        let submission = TaskTurnSubmissionService.submit(
            message: message,
            attachmentPaths: attachmentPaths,
            for: task,
            into: modelContext
        )
        guard case let .success(savedTurn) = submission else {
            AppLogger.audit(.runtimePersistenceSummary, category: "UI", taskID: task.id, fields: [
                "operation": "turn_submission",
                "result": "failed"
            ], level: .error)
            if case let .failure(error) = submission { return .failure(error) }
            return .failure(.persistenceFailed("unknown"))
        }
        if task.isDone { task.isDone = false } // reopen: sidebar review/unread predicates gate on !isDone
        var runsInterrupted = 0
        if task.status != .running {
            let interruptionSummary = TaskRunLifecycleService.cancelTask(
                task,
                modelContext: modelContext,
                source: .supersededByNewRun
            )
            runsInterrupted = interruptionSummary.runsUpdated
            if interruptionSummary.runsUpdated > 0 {
                AppLogger.audit(.taskInterrupted, category: "UI", taskID: task.id, fields: [
                    "source": TaskRunInterruptionSource.supersededByNewRun.auditSource,
                    "running_runs_cancelled": String(interruptionSummary.runsUpdated),
                    "next_action": "continue_session"
                ], level: .warning)
            }
        }
        var capabilityFields = CapabilityAudit.taskContextFields(source: source, task: task)
        capabilityFields["trace_id"] = traceID
        AppLogger.audit(.capabilityChatContext, category: "UI", taskID: task.id, fields: capabilityFields, level: .info, fieldMaxLength: 240)
        recordPolicyLevelIfChanged(policyLevel, task: task, source: source, modelContext: modelContext)
        taskQueue.signalExecutionRequest(
            id: savedTurn.requestID,
            task: task,
            modelContext: modelContext
        )
        return .success(Continuation(requestID: savedTurn.requestID, runsInterrupted: runsInterrupted))
    }

    static func recordPolicyLevelIfChanged(
        _ level: AgentPolicyLevel,
        task: AgentTask,
        source: String,
        modelContext: ModelContext
    ) {
        guard TaskPolicyStore.latestSelectedLevel(for: task) != level else { return }
        TaskPolicyStore.recordSelection(
            level: level,
            task: task,
            modelContext: modelContext,
            source: source
        )
    }
}
