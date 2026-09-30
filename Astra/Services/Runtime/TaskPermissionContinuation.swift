import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Resolves execution intent from the durable approval and its originating turn.
/// No UI state or provider prose decides whether an approval restarts work.
@MainActor
enum TaskPermissionContinuation {
    static func capture(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        mode: PermissionApprovalContinuation.Mode = .relaunch
    ) -> PermissionApprovalContinuation {
        let request = (try? TaskTurnRequestRepository.requests(for: task, in: modelContext))?
            .last { $0.runID == run.id }
        let source = request.flatMap { request in task.events.first { $0.id == request.sourceEventID } }
        let priorContinuation = source.flatMap(ExecutionRequestSubmissionService.decodeSourcePayload)?.permissionContinuation
        let userEvent = task.events
            .filter { $0.type == "user.message" && $0.timestamp <= run.startedAt }
            .max { $0.timestamp < $1.timestamp }
        let original = priorContinuation?.originalUserRequest
            ?? (source?.type == "user.message" ? source?.payload : nil)
            ?? request?.executionPolicySnapshot?.turnIntentSnapshot?.acceptedTurn
            ?? userEvent?.payload
            ?? task.goal
        return PermissionApprovalContinuation(
            runID: run.id,
            sourceEventID: source?.id ?? userEvent?.id,
            originalUserRequest: original,
            mode: mode
        )
    }

    static func binding(
        payload: String,
        task: AgentTask,
        modelContext: ModelContext
    ) -> PermissionApprovalContinuation? {
        let approval = PermissionApprovalEventPayload.decoded(from: payload)
        guard approval?.behavior != .futureUse else { return nil }
        if let continuation = approval?.continuation { return continuation }
        // Older connector requests were actual blocked calls but labelled as
        // offers. Bind them to their event's run, never to the newest user turn.
        guard let event = task.events.filter({
            ($0.type == "permission.approval.requested" || $0.type == "permission.denied")
                && $0.payload == payload
        }).max(by: { $0.timestamp < $1.timestamp }), let run = event.run else { return nil }
        guard task.status == .pendingUser
            || approval?.requestID?.hasPrefix(BrokeredCredentialApprovalRecord.offerRequestIDPrefix) == true else {
            return nil
        }
        return capture(task: task, run: run, modelContext: modelContext)
    }

    static func isCurrent(_ binding: PermissionApprovalContinuation, task: AgentTask, modelContext: ModelContext,
                          recoveringRestart: Bool = false) throws -> Bool {
        guard !task.isDone,
              let run = task.runs.first(where: { $0.id == binding.runID }),
              !task.runs.contains(where: { $0.id != run.id && $0.startedAt > run.startedAt }) else { return false }
        if task.status == .cancelled {
            let interruption = task.events.filter {
                $0.type == TaskEventTypes.Task.interrupted.rawValue || $0.type == TaskEventTypes.Task.cancelled.rawValue
            }.max { $0.timestamp < $1.timestamp }
            guard recoveringRestart, run.typedStopReason == .appRestarted,
                  interruption?.type == TaskEventTypes.Task.interrupted.rawValue,
                  interruption?.run?.id == run.id else { return false }
        }
        // A queued user turn supersedes this request even before it gets a run.
        let requests = try TaskTurnRequestRepository.requests(for: task, in: modelContext)
        if let origin = requests.last(where: { $0.runID == run.id }),
           requests.contains(where: { $0.sequence > origin.sequence }) { return false }
        let cutoff = binding.sourceEventID.flatMap { id in task.events.first { $0.id == id }?.timestamp }
            ?? run.startedAt
        return !task.events.contains {
            $0.type == "user.message" && $0.id != binding.sourceEventID && $0.timestamp > cutoff
        }
    }

    static func turnIntent(_ binding: PermissionApprovalContinuation, task: AgentTask, sourceEventID: UUID, modelContext: ModelContext) -> TaskTurnIntentSnapshot {
        let origin = (try? TaskTurnRequestRepository.requests(for: task, in: modelContext))?
            .last(where: { $0.runID == binding.runID })?.executionPolicySnapshot?.turnIntentSnapshot
        let fallback = TaskTurnIntentResolver.capture(
            for: task, sourceEventID: sourceEventID, acceptedTurn: binding.originalUserRequest, includeTaskInputs: false
        )
        let intent = origin ?? fallback
        return TaskTurnIntentSnapshot(
            taskID: task.id, sourceEventID: sourceEventID, acceptedTurn: binding.originalUserRequest,
            inheritedTurn: intent.inheritedTurn, activeObjective: intent.activeObjective,
            attachmentPaths: intent.attachmentPaths, pinnedSkillIDs: intent.pinnedSkillIDs, isReferential: intent.isReferential
        )
    }

    static func attach(_ payload: String, continuation: PermissionApprovalContinuation,
                       behavior: PermissionApprovalBehavior = .continueBlockedTurn) -> String {
        guard var decoded = PermissionApprovalEventPayload.decoded(from: payload) else { return payload }
        decoded.behavior = behavior
        decoded.continuation = continuation
        decoded.requestID = decoded.requestID ?? UUID().uuidString
        return decoded.encodedString() ?? payload
    }

    @discardableResult
    static func applyBlockingOutcomeIfNeeded(task: AgentTask, run: TaskRun, modelContext: ModelContext) -> Bool {
        guard !task.isDone, task.status != .cancelled else { return false }
        let requests = TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task).filter { payload in
            if let approval = PermissionApprovalEventPayload.decoded(from: payload),
               approval.behavior == .futureUse {
                return approval.requestID?.hasPrefix(BrokeredCredentialApprovalRecord.offerRequestIDPrefix) == true
                    && approval.continuation?.runID == run.id
            }
            return binding(payload: payload, task: task, modelContext: modelContext)?.runID == run.id
        }
        guard !requests.isEmpty else { return false }
        for payload in requests where PermissionApprovalEventPayload.decoded(from: payload)?.behavior == .futureUse {
            let promoted = attach(payload, continuation: capture(task: task, run: run, modelContext: modelContext))
            TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: promoted, task: task)
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionApprovalRequested,
                payload: promoted, run: run))
        }
        run.recordPermissionApprovalRequired()
        TaskStateMachine.pauseForRuntimePermission(task, modelContext: modelContext)
        return true
    }

    static func legacyResumeMessage(_ message: String, task: AgentTask, payload: String) -> String {
        let cutoff = task.events.filter { $0.payload == payload }.map(\.timestamp).max() ?? .distantFuture
        let user = task.events.filter { $0.type == "user.message" && $0.timestamp <= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
            .first { !TaskContextStateManager.isGeneratedResumeInstruction($0.payload) }
        return message + "\n\nOriginal blocked user request: \(user?.payload ?? task.goal)\n\n"
            + "Continue by answering that request now. Do not answer an earlier turn or the approval notice itself."
    }

    static func resumeMessage(_ message: String, binding: PermissionApprovalContinuation) -> String {
        message + "\n\nOriginal blocked user request: \(binding.originalUserRequest)\n\n"
            + "Continue by answering that request now. Do not answer an earlier turn or the approval notice itself. "
            + "Inspect existing results before retrying actions; do not repeat completed external changes."
    }
}
