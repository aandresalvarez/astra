import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskExecutionLaunchMode: String, Codable, Sendable {
    case initial
    case continuation
    case approvedPlan = "approved_plan"
}

/// Typed source metadata for non-user-authored execution requests. User chat
/// keeps its append-only `user.message` event as the source of truth; internal
/// launches use this envelope so recovery never depends on an in-memory closure.
struct TaskExecutionSourcePayloadV1: Codable, Equatable, Sendable {
    let version: Int
    let launchMode: TaskExecutionLaunchMode
    let message: String?
    let planID: UUID?
    let planSnapshot: TaskPlanPayload?
    let planExecutionModeRawValue: String?
    let scheduleID: UUID?
    let sourceTaskID: UUID?
    let executionPolicyOverride: TaskExecutionPolicyOverrideV1?

    init(
        launchMode: TaskExecutionLaunchMode,
        message: String? = nil,
        plan: TaskPlanPayload? = nil,
        planExecutionMode: TaskPlanExecutionMode? = nil,
        scheduleID: UUID? = nil,
        sourceTaskID: UUID? = nil,
        executionPolicy: AgentRuntimeExecutionPolicy? = nil
    ) {
        version = 1
        self.launchMode = launchMode
        self.message = message
        self.planID = plan?.planID
        self.planSnapshot = plan
        self.planExecutionModeRawValue = planExecutionMode?.rawValue
        self.scheduleID = scheduleID
        self.sourceTaskID = sourceTaskID
        self.executionPolicyOverride = executionPolicy.map(TaskExecutionPolicyOverrideV1.init)
    }

    var planExecutionMode: TaskPlanExecutionMode? {
        planExecutionModeRawValue.flatMap(TaskPlanExecutionMode.init(rawValue:))
    }
}

struct TaskExecutionPolicyOverrideV1: Codable, Equatable, Sendable {
    let permissionPolicyRawValue: String?
    let allowedTools: [String]?
    let permissionGrants: [PermissionGrant]?
    let providerRender: ProviderPolicyRender?

    init(_ policy: AgentRuntimeExecutionPolicy) {
        permissionPolicyRawValue = policy.permissionPolicyOverride?.rawValue
        allowedTools = policy.allowedToolsOverride
        permissionGrants = policy.permissionGrantsOverride
        providerRender = policy.providerRenderOverride
    }

    var executionPolicy: AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: permissionPolicyRawValue.flatMap(PermissionPolicy.init(rawValue:)),
            allowedToolsOverride: allowedTools,
            permissionGrantsOverride: permissionGrants,
            providerRenderOverride: providerRender
        )
    }
}

/// The single durable submission boundary for provider-bound task execution.
/// It persists a typed source event and immutable V16 request snapshot in one
/// save. Starting provider work is deliberately a separate queue signal that
/// callers may issue only after this API succeeds.
@MainActor
enum ExecutionRequestSubmissionService {
    enum PlanTaskMutation {
        case newTask(title: String, goal: String, runtimeExplicitlySelected: Bool)
        case existingTask
    }
    struct Submission: Equatable {
        let requestID: UUID
        let eventID: UUID
        let sequence: Int
    }

    enum SubmissionError: Error, Equatable {
        case emptySource
        case persistenceFailed(String)
    }

    static func submitFollowUp(
        message: String,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date()
    ) -> Result<Submission, SubmissionError> {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptySource) }
        return submit(
            kind: .followUp,
            sourceEventType: TaskEventTypes.Conversation.userMessage.rawValue,
            sourcePayload: trimmed,
            task: task,
            modelContext: modelContext,
            at: date
        )
    }

    static func submitInitial(
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date()
    ) -> Result<Submission, SubmissionError> {
        return submitInternal(
            kind: .initial,
            eventType: TaskEventTypes.ExecutionRequest.initial.rawValue,
            payload: TaskExecutionSourcePayloadV1(launchMode: .initial),
            task: task,
            modelContext: modelContext,
            at: date
        )
    }

    static func submitRetry(
        message: String?,
        continuation: Bool,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date(),
        prepare: () -> Void = {},
        rollback: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        submitInternal(
            kind: .retry,
            eventType: TaskEventTypes.ExecutionRequest.retry.rawValue,
            payload: TaskExecutionSourcePayloadV1(
                launchMode: continuation ? .continuation : .initial,
                message: message
            ),
            task: task,
            modelContext: modelContext,
            at: date,
            prepare: prepare,
            rollback: rollback
        )
    }

    static func submitResume(
        message: String,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date(),
        prepare: () -> Void = {},
        rollback: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        submitInternal(
            kind: .followUp,
            eventType: TaskEventTypes.ExecutionRequest.resume.rawValue,
            payload: TaskExecutionSourcePayloadV1(launchMode: .continuation, message: message),
            task: task,
            modelContext: modelContext,
            at: date,
            prepare: prepare,
            rollback: rollback
        )
    }

    static func submitPermissionResume(
        message: String,
        executionPolicy: AgentRuntimeExecutionPolicy,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date(),
        prepare: () -> Void = {},
        rollback: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        submitInternal(
            kind: .followUp,
            eventType: TaskEventTypes.ExecutionRequest.permissionResume.rawValue,
            payload: TaskExecutionSourcePayloadV1(
                launchMode: .continuation,
                message: message,
                executionPolicy: executionPolicy
            ),
            task: task,
            modelContext: modelContext,
            at: date,
            prepare: prepare,
            rollback: rollback
        )
    }

    static func submitScheduled(
        scheduleID: UUID,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date(),
        prepare: () -> Void = {},
        rollback: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        submitInternal(
            kind: .scheduled,
            eventType: TaskEventTypes.ExecutionRequest.scheduled.rawValue,
            payload: TaskExecutionSourcePayloadV1(launchMode: .initial, scheduleID: scheduleID),
            task: task,
            modelContext: modelContext,
            at: date,
            prepare: prepare,
            rollback: rollback
        )
    }

    static func submitChained(
        sourceTaskID: UUID,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date()
    ) -> Result<Submission, SubmissionError> {
        submitInternal(
            kind: .initial,
            eventType: TaskEventTypes.ExecutionRequest.chained.rawValue,
            payload: TaskExecutionSourcePayloadV1(launchMode: .initial, sourceTaskID: sourceTaskID),
            task: task,
            modelContext: modelContext,
            at: date
        )
    }

    static func submitPlan(
        plan: TaskPlanPayload,
        mode: TaskPlanExecutionMode,
        mutation: PlanTaskMutation,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date(),
        recordAdditionalPolicy: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        let stateSnapshot = TaskStateMachine.snapshot(task)
        let previousUpdatedAt = task.updatedAt
        let previousUnreadAt = task.unreadAt
        let previousTitle = task.title
        let previousGoal = task.goal
        let previousRuntimeExplicitlySelected = task.runtimeExplicitlySelected
        let previousEventIDs = Set(task.events.map(\.id))
        return submitInternal(
            kind: .planStep,
            eventType: TaskEventTypes.ExecutionRequest.planStep.rawValue,
            payload: TaskExecutionSourcePayloadV1(
                launchMode: .approvedPlan,
                plan: plan,
                planExecutionMode: mode
            ),
            task: task,
            modelContext: modelContext,
            at: date,
            prepare: {
                recordAdditionalPolicy()
                TaskPlanService.recordApproved(plan, task: task, modelContext: modelContext)
                switch mutation {
                case .newTask(let title, let goal, let runtimeExplicitlySelected):
                    task.title = title
                    task.goal = goal
                    task.runtimeExplicitlySelected = runtimeExplicitlySelected
                    TaskStateMachine.enqueueFromChatSubmission(task, modelContext: modelContext)
                case .existingTask:
                    TaskStateMachine.enqueueApprovedPlanRun(task, modelContext: modelContext)
                }
            },
            rollback: {
                TaskStateMachine.restoreExecutionSubmissionFailure(
                    task,
                    snapshot: stateSnapshot,
                    modelContext: modelContext,
                    at: previousUpdatedAt
                )
                task.updatedAt = previousUpdatedAt
                task.unreadAt = previousUnreadAt
                task.title = previousTitle
                task.goal = previousGoal
                task.runtimeExplicitlySelected = previousRuntimeExplicitlySelected
                for event in task.events where !previousEventIDs.contains(event.id) && !event.isDeleted {
                    modelContext.delete(event)
                }
            }
        )
    }

    static func decodeSourcePayload(_ event: TaskEvent) -> TaskExecutionSourcePayloadV1? {
        guard let data = event.payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskExecutionSourcePayloadV1.self, from: data)
    }

    private static func submitInternal(
        kind: TaskExecutionRequestKind,
        eventType: String,
        payload: TaskExecutionSourcePayloadV1,
        task: AgentTask,
        modelContext: ModelContext,
        at date: Date,
        prepare: () -> Void = {},
        rollback: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        guard let data = try? JSONEncoder().encode(payload),
              let encoded = String(data: data, encoding: .utf8) else {
            return .failure(.persistenceFailed("source_encoding_failed"))
        }
        return submit(
            kind: kind,
            sourceEventType: eventType,
            sourcePayload: encoded,
            task: task,
            modelContext: modelContext,
            at: date,
            prepare: prepare,
            rollback: rollback
        )
    }

    private static func submit(
        kind: TaskExecutionRequestKind,
        sourceEventType: String,
        sourcePayload: String,
        task: AgentTask,
        modelContext: ModelContext,
        at date: Date,
        prepare: () -> Void = {},
        rollback: () -> Void = {}
    ) -> Result<Submission, SubmissionError> {
        let nextSequence: Int
        do {
            nextSequence = try TaskTurnRequestRepository.nextSequence(for: task, in: modelContext)
        } catch {
            return .failure(.persistenceFailed(String(describing: type(of: error))))
        }

        prepare()
        let event = TaskEvent(task: task, type: sourceEventType, payload: sourcePayload)
        event.timestamp = date
        let request = TaskTurnRequest(
            task: task,
            messageEventID: event.id,
            sequence: nextSequence,
            kind: kind,
            resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task),
            submittedAt: date
        )
        modelContext.insert(event)
        modelContext.insert(request)

        let auditFields = [
            "operation": "execution_request_submission",
            "request_id": request.id.uuidString,
            "request_kind": kind.rawValue
        ]
        do {
            if task.status == .running {
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: auditFields
                )
            } else {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: auditFields
                )
            }
        } catch {
            modelContext.delete(request)
            modelContext.delete(event)
            rollback()
            return .failure(.persistenceFailed(String(describing: type(of: error))))
        }

        TaskEventInsertionService.publishInsertion(for: event)
        TaskThreadChangeNotifier.post(taskID: task.id, source: "execution_request_submitted")
        return .success(Submission(requestID: request.id, eventID: event.id, sequence: nextSequence))
    }

}
