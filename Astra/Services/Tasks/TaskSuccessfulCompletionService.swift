import Foundation
import SwiftData
import ASTRAModels

/// Owns the deterministic transition from successful provider work to either
/// task completion or a typed ASTRA review gate.
enum TaskSuccessfulCompletionService {
    @MainActor
    static func apply(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        successPayload: String,
        permissionPolicy: PermissionPolicy
    ) -> Bool {
        // Registration is normally created at the exact typed tool-result
        // boundary. Reconciliation here closes the process-crash window where
        // the backend record was committed but the provider/app exited before
        // SwiftData registration.
        TaskExternalOperationRegistrationService.reconcileTrustedBackendRecords(
            task: task,
            modelContext: modelContext
        )

        let operations = TaskExternalOperationRegistrationService.operations(
            taskID: task.id,
            modelContext: modelContext
        )
        if let validation = operations.first(where: {
            $0.monitoringState == .validating && $0.originatingRunID != run.id
        }) {
            // A successful fresh provider run is the validation boundary.
            // Process exit 0 only moved the operation to `validating`; it did
            // not complete the task by itself.
            validation.monitoringState = .completed
            validation.updatedAt = Date()
            validation.nextCheckAt = nil
        }

        // Completing one validation never supersedes another task-owned
        // operation. Re-evaluate the full set after the mutation above so a
        // remaining active or validating row keeps the task waitingExternal.
        if let operation = operations.first(where: {
            $0.monitoringState == .active || $0.monitoringState == .validating
        }) {
            // An ambiguity/reasoning wake does not supersede the still-running
            // external operation. A successful explanatory provider turn
            // returns the task to durable monitoring.
            pauseForMonitoring(operation: operation, task: task, run: run, modelContext: modelContext)
            return false
        }

        if let operation = operations.first(where: {
            $0.monitoringState == .completed
                && $0.executionState.isTerminalObservation
                && $0.executionState != .processCompleted
        }) {
            if operation.originatingRunID == run.id {
                // The originating provider turn cannot convert an already
                // terminal external failure into task success. Keep the task
                // waiting until the operation-specific reasoning wake runs.
                pauseForMonitoring(operation: operation, task: task, run: run, modelContext: modelContext)
                return false
            }
            // A reasoning wake may explain cancellation/failure/interruption,
            // but successful narration is not successful external work.
            let completedAt = run.completedAt ?? Date()
            run.completedAt = completedAt
            run.recordExternalOutcomePending()
            TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext, at: completedAt)
            modelContext.insert(TaskEvent(
                task: task,
                type: "externalOperation.review.required",
                payload: TaskEvent.payloadString([
                    "execution_state": operation.executionState.rawValue,
                    "operation_id": operation.id.uuidString
                ]),
                run: run
            ))
            return false
        }

        if permissionPolicy != .autonomous {
            TaskRuntimeOutcomeTransition.queueGitHubPullRequestIfNeeded(
                task: task,
                run: run,
                modelContext: modelContext
            )
        }
        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
            task: task,
            run: run,
            permissionPolicy: permissionPolicy
        )
        if decision.shouldBlockCompletion {
            TaskRuntimeOutcomeTransition.applyCompletionBlock(
                decision,
                task: task,
                run: run,
                modelContext: modelContext
            )
            return false
        }

        TaskStateMachine.completeFromRuntime(task, modelContext: modelContext)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.completed,
            payload: successPayload,
            run: run
        ))
        return true
    }

    @MainActor
    private static func pauseForMonitoring(
        operation: TaskExternalOperation,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        let completedAt = run.completedAt ?? Date()
        run.completedAt = completedAt
        run.recordExternalOutcomePending()
        TaskStateMachine.pauseForMonitoredExternalOperation(
            task,
            modelContext: modelContext,
            at: completedAt
        )
        let alreadyRecorded = task.events.contains {
            $0.run?.id == run.id && $0.type == "externalOperation.monitoring.started"
        }
        if !alreadyRecorded {
            modelContext.insert(TaskEvent(
                task: task,
                type: "externalOperation.monitoring.started",
                payload: TaskEvent.payloadString([
                    "backend": operation.backendKindRaw,
                    "external_identity": operation.externalIdentity,
                    "originating_run_id": operation.originatingRunID.uuidString
                ]),
                run: run
            ))
        }
    }

    /// Re-runs non-publication completion gates after a durable external
    /// outcome receipt. User approval authorizes the reviewed publication; it
    /// does not authorize bypassing missing deliverables.
    @MainActor
    static func applyAfterRequiredExternalOutcome(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) -> Bool {
        let decision = TaskCompletionPolicy.decideAfterRequiredExternalOutcome(
            task: task,
            run: run
        )
        if decision.shouldBlockCompletion {
            TaskRuntimeOutcomeTransition.applyCompletionBlock(
                decision,
                task: task,
                run: run,
                modelContext: modelContext
            )
            return false
        }

        let completedAt = Date()
        run.recordExternalOutcomeCompleted(at: completedAt)
        TaskStateMachine.completeFromUserApproval(
            task,
            modelContext: modelContext,
            at: completedAt
        )
        return true
    }
}
