import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
enum TaskStateMachine {
    enum Rejection: Equatable {
        case illegalTransition
    }

    enum SavePolicy: Equatable {
        case none
        case save
    }

    enum ReadState {
        case preserve
        case read
        case unread
    }

    struct Snapshot: Equatable {
        let status: TaskStatus
        let completedAt: Date?

        init(task: AgentTask) {
            status = task.status
            completedAt = task.completedAt
        }

        init(status: TaskStatus, completedAt: Date?) {
            self.status = status
            self.completedAt = completedAt
        }
    }

    struct TransitionResult: Equatable {
        let from: TaskStatus
        let to: TaskStatus
        let changed: Bool
        let rejection: Rejection?
    }

    static func snapshot(_ task: AgentTask) -> Snapshot {
        Snapshot(task: task)
    }

    @discardableResult
    static func enqueueFromUserSubmission(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "user_submission_queued",
            allowedFrom: [.draft],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueFromChatSubmission(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "chat_submission_queued",
            allowedFrom: [.draft],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueFromScheduler(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "scheduler_queued",
            allowedFrom: [.draft],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueFromWorkspaceCommand(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "workspace_command_queued",
            allowedFrom: [.draft],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueFromUITestSeed(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "ui_test_seed_queued",
            allowedFrom: [.draft],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueApprovedPlanRun(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "approved_plan_queued",
            allowedFrom: Set(TaskStatus.allCases).subtracting([.running]),
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueChainedFollowUp(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "chained_follow_up_queued",
            allowedFrom: [.draft],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func enqueueFromRetry(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .queued,
            intent: "retry_queued",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func restoreDraftForEditing(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .draft,
            intent: "queued_task_returned_to_draft",
            allowedFrom: [.queued],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func admitQueuedTaskToRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .running,
            intent: "queue_admission_running",
            allowedFrom: [.queued],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func markRuntimeSessionStarted(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .running,
            intent: "runtime_session_started",
            allowedFrom: [.running],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func admitContinuationToRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .running,
            intent: "continuation_admission_running",
            allowedFrom: Set(TaskStatus.allCases).subtracting([.draft]),
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func restoreContinuationAdmissionFailure(
        _ task: AgentTask,
        snapshot: Snapshot,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: snapshot.status,
            intent: "continuation_admission_rejected",
            allowedFrom: [.running, snapshot.status],
            completedAt: .restore(snapshot.completedAt),
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func completeFromRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .completed,
            intent: "runtime_completed",
            allowedFrom: [.running, .pendingUser],
            completedAt: .set(date),
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func completeFromUserApproval(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .completed,
            intent: "user_approved_completed",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(date),
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func completeFromSessionRecovery(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .completed,
            intent: "session_recovery_completed",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(task.completedAt ?? date),
            readState: .preserve,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func failFromRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        markUnread: Bool = true,
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .failed,
            intent: "runtime_failed",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(date),
            readState: markUnread ? .unread : .preserve,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func failFromValidation(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .failed,
            intent: "validation_failed",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(date),
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func cancelFromLifecycle(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .cancelled,
            intent: "lifecycle_cancelled",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(date),
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func cancelFromRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .cancelled,
            intent: "runtime_cancelled",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(date),
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func pauseForRuntimePermission(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .pendingUser,
            intent: "runtime_permission_pending_user",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .clear,
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func pauseForValidationReview(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .pendingUser,
            intent: "validation_pending_user",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .clear,
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func pauseForExternalOutcome(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .pendingUser,
            intent: "external_outcome_pending_user",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .clear,
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func pauseForRuntimeReview(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .pendingUser,
            intent: "runtime_review_pending_user",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .clear,
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func resumeAfterRuntimePermission(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .running,
            intent: "runtime_permission_resolved_running",
            allowedFrom: [.pendingUser, .running],
            completedAt: .clear,
            readState: .read,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func exceedBudgetFromRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .budgetExceeded,
            intent: "runtime_budget_exceeded",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .set(date),
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func setFromBoardMove(
        _ task: AgentTask,
        to status: TaskStatus,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: status,
            intent: "board_move",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: completedAtRule(for: status, at: date),
            readState: readState(for: status),
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func initializeFromWorkspaceAppAction(
        _ task: AgentTask,
        to status: TaskStatus,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: status,
            intent: "workspace_app_action_task_initialized",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: completedAtRule(for: status, at: date),
            readState: readState(for: status),
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func restoreImportedStatus(
        _ task: AgentTask,
        to status: TaskStatus,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: status,
            intent: "imported_status_restored",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .preserve,
            readState: .preserve,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func mirrorScheduleResultStatus(
        sourceTask: AgentTask,
        scheduledTask: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            sourceTask,
            to: scheduledTask.status,
            intent: "schedule_result_status_mirrored",
            allowedFrom: Set(TaskStatus.allCases),
            completedAt: .restore(sourceTask.completedAt),
            readState: .unread,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    @discardableResult
    static func initializeForkAsCompleted(
        _ task: AgentTask,
        modelContext: ModelContext,
        at date: Date = Date(),
        savePolicy: SavePolicy = .none
    ) -> TransitionResult {
        apply(
            task,
            to: .completed,
            intent: "fork_initialized_completed",
            allowedFrom: [.draft, .completed],
            completedAt: .preserve,
            readState: .preserve,
            modelContext: modelContext,
            at: date,
            savePolicy: savePolicy
        )
    }

    private enum CompletedAtRule {
        case preserve
        case clear
        case set(Date)
        case restore(Date?)
    }

    @discardableResult
    private static func apply(
        _ task: AgentTask,
        to status: TaskStatus,
        intent: String,
        allowedFrom: Set<TaskStatus>,
        completedAt: CompletedAtRule,
        readState: ReadState,
        modelContext: ModelContext,
        at date: Date,
        savePolicy: SavePolicy
    ) -> TransitionResult {
        let previousStatus = task.status
        guard allowedFrom.contains(previousStatus) else {
            AppLogger.audit(.taskStatusChanged, category: "TaskState", taskID: task.id, fields: [
                "intent": intent,
                "from": previousStatus.rawValue,
                "to": status.rawValue,
                "result": "rejected_illegal_transition"
            ], level: .warning)
            return TransitionResult(
                from: previousStatus,
                to: status,
                changed: false,
                rejection: .illegalTransition
            )
        }

        let changed = previousStatus != status
        task.status = status
        apply(completedAt, to: task)
        task.updatedAt = date
        apply(readState, to: task, at: date)
        persistIfNeeded(task: task, modelContext: modelContext, savePolicy: savePolicy)

        AppLogger.audit(.taskStatusChanged, category: "TaskState", taskID: task.id, fields: [
            "intent": intent,
            "from": previousStatus.rawValue,
            "to": status.rawValue,
            "changed": String(changed),
            "result": "applied"
        ], level: .debug)

        return TransitionResult(
            from: previousStatus,
            to: status,
            changed: changed,
            rejection: nil
        )
    }

    private static func completedAtRule(for status: TaskStatus, at date: Date) -> CompletedAtRule {
        switch status {
        case .draft, .queued, .running, .pendingUser:
            return .clear
        case .completed, .failed, .cancelled, .budgetExceeded:
            return .set(date)
        }
    }

    private static func readState(for status: TaskStatus) -> ReadState {
        switch status {
        case .draft, .queued, .running, .cancelled:
            return .read
        case .pendingUser, .completed, .failed, .budgetExceeded:
            return .unread
        }
    }

    private static func apply(_ completedAtRule: CompletedAtRule, to task: AgentTask) {
        switch completedAtRule {
        case .preserve:
            break
        case .clear:
            task.completedAt = nil
        case .set(let date):
            task.completedAt = date
        case .restore(let date):
            task.completedAt = date
        }
    }

    private static func apply(_ readState: ReadState, to task: AgentTask, at date: Date) {
        switch readState {
        case .preserve:
            break
        case .read:
            task.markRead()
        case .unread:
            task.markUnreadForCurrentStatus(at: date)
        }
    }

    private static func persistIfNeeded(
        task: AgentTask,
        modelContext: ModelContext,
        savePolicy: SavePolicy
    ) {
        guard savePolicy == .save else { return }
        // Status transitions must be durably persisted before workers observe
        // them, so this always uses the coordinator's synchronous save path,
        // never the debounced `scheduleAutoExport`. `TaskStateMachine` is
        // `@MainActor`-isolated (see the type declaration above), and
        // `WorkspacePersistenceCoordinator` is likewise `@MainActor`, so this
        // call is statically verified to run on the main actor -- no runtime
        // assumption required.
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "task_state_machine_save"]
        )
    }
}

/// Nonisolated backing implementation for the task-transition seams declared
/// in `ASTRACore/TaskForkLifecycleSeams.swift`.
///
/// This mirrors `initializeForkAsCompleted(_:modelContext:...)`'s guard and
/// audit shape rather than calling through to it, since that method needs a
/// live `AgentTask`/`ModelContext` the seam boundary can't carry. This is
/// the one piece of pure transition logic duplicated across the seam boundary.
/// Keeping it in this nonisolated adapter prevents a `@MainActor` state-machine
/// type from satisfying a nonisolated, `Sendable` service protocol.
enum TaskStateTransitionSeamAdapter: TaskForkStateInitializing, TaskSessionStateApplying {
    static func initializeForkAsCompleted(
        taskID: UUID,
        statusRawValue: String,
        at date: Date
    ) -> TaskForkStateInitializationResult {
        let allowedFrom: Set<TaskStatus> = [.draft, .completed]
        guard let currentStatus = TaskStatus(rawValue: statusRawValue),
              allowedFrom.contains(currentStatus) else {
            AppLogger.audit(.taskStatusChanged, category: "TaskState", taskID: taskID, fields: [
                "intent": "fork_initialized_completed",
                "from": statusRawValue,
                "to": TaskStatus.completed.rawValue,
                "result": "rejected_illegal_transition"
            ], level: .warning)
            return TaskForkStateInitializationResult(statusRawValue: statusRawValue, updatedAt: nil, applied: false)
        }

        AppLogger.audit(.taskStatusChanged, category: "TaskState", taskID: taskID, fields: [
            "intent": "fork_initialized_completed",
            "from": currentStatus.rawValue,
            "to": TaskStatus.completed.rawValue,
            "changed": String(currentStatus != .completed),
            "result": "applied"
        ], level: .debug)
        return TaskForkStateInitializationResult(statusRawValue: TaskStatus.completed.rawValue, updatedAt: date, applied: true)
    }
    static func completeFromSessionRecovery(
        taskID: UUID,
        currentStatusRawValue: String,
        existingCompletedAt: Date?,
        at date: Date
    ) -> TaskSessionRecoveryCompletionResult {
        let previousStatus = TaskStatus(rawValue: currentStatusRawValue) ?? .draft
        AppLogger.audit(.taskStatusChanged, category: "TaskState", taskID: taskID, fields: [
            "intent": "session_recovery_completed",
            "from": previousStatus.rawValue,
            "to": TaskStatus.completed.rawValue,
            "changed": String(previousStatus != .completed),
            "result": "applied"
        ], level: .debug)
        return TaskSessionRecoveryCompletionResult(completedAt: existingCompletedAt ?? date, updatedAt: date)
    }

    static func restoreImportedStatus(
        taskID: UUID,
        currentStatusRawValue: String,
        targetStatusRawValue: String,
        at date: Date
    ) -> TaskImportedStatusRestorationResult {
        let previousStatus = TaskStatus(rawValue: currentStatusRawValue) ?? .draft
        let targetStatus = TaskStatus(rawValue: targetStatusRawValue) ?? .completed
        AppLogger.audit(.taskStatusChanged, category: "TaskState", taskID: taskID, fields: [
            "intent": "imported_status_restored",
            "from": previousStatus.rawValue,
            "to": targetStatus.rawValue,
            "changed": String(previousStatus != targetStatus),
            "result": "applied"
        ], level: .debug)
        return TaskImportedStatusRestorationResult(updatedAt: date)
    }
}
