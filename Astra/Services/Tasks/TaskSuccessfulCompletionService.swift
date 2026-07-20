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
        permissionPolicy: PermissionPolicy,
        validatingOperationID: UUID? = nil
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
        if let validatingOperationID,
           let validation = operations.first(where: {
               $0.id == validatingOperationID
                   && $0.monitoringState == .validating
                   && $0.originatingRunID != run.id
           }) {
            // A successful fresh provider run is the validation boundary — but
            // only for the operation whose wake actually launched this run.
            // Without the ID match, any successful non-originating run (a user
            // follow-up sent while validation is pending, or a wake for a
            // different operation) would consume this operation's validating
            // state and let the task complete without validating it. Process
            // exit 0 only moved the operation to `validating`; it did not
            // complete the task by itself.
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
            // Unlike the `.active`/`.validating` check above, a stale
            // `.completed` terminal-failure row is otherwise never cleared, so
            // without the ID gate here ANY future successful run on this task —
            // including ones with nothing to do with this operation — would
            // re-enter "review required" forever. Only the run that produced
            // the failure, or the run dispatched as ITS OWN reasoning wake, may
            // match.
            $0.monitoringState == .completed
                && $0.executionState.isTerminalObservation
                && $0.executionState != .processCompleted
                && ($0.originatingRunID == run.id || $0.id == validatingOperationID)
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

        // A DIFFERENT operation's terminal failure whose required review the
        // user never resolved must not be erased by this operation's success.
        // With one failed and one successful operation, the failure's reasoning
        // wake can finish first and place the task in runtime review; the
        // success validation wake is still admitted from that state, and
        // without this check it would complete the task, silently discarding
        // the pending review (the failed wake is already acknowledged, so
        // monitoring has nothing left to deliver). "Resolved" is the user's
        // explicit approval (`task.approved`) recorded at/after the failure's
        // `review.required` event; a failure row whose reasoning wake has not
        // even fired yet is likewise unresolved.
        if let unreviewed = operations.first(where: { operation in
            operation.monitoringState == .completed
                && operation.executionState.isTerminalObservation
                && operation.executionState != .processCompleted
                && operation.id != validatingOperationID
                && operation.originatingRunID != run.id
                && !hasResolvedFailureReview(operation: operation, task: task)
        }) {
            let completedAt = run.completedAt ?? Date()
            run.completedAt = completedAt
            run.recordExternalOutcomePending()
            TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext, at: completedAt)
            modelContext.insert(TaskEvent(
                task: task,
                type: "externalOperation.review.required",
                payload: TaskEvent.payloadString([
                    "execution_state": unreviewed.executionState.rawValue,
                    "operation_id": unreviewed.id.uuidString
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

    /// A terminal failure's review is resolved only by the user's explicit
    /// approval recorded at/after the failure's `review.required` event. No
    /// `review.required` event at all means the failure's reasoning wake has
    /// not fired yet — also unresolved.
    @MainActor
    private static func hasResolvedFailureReview(
        operation: TaskExternalOperation,
        task: AgentTask
    ) -> Bool {
        let operationID = operation.id.uuidString
        guard let reviewRequiredAt = task.events
            .filter({ $0.type == "externalOperation.review.required" && $0.payload.contains(operationID) })
            .map(\.timestamp)
            .max() else {
            return false
        }
        return task.events.contains {
            $0.type == TaskEventTypes.Task.approved.rawValue && $0.timestamp >= reviewRequiredAt
        }
    }

    @MainActor
    private static func pauseForMonitoring(
        operation: TaskExternalOperation,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        _ = TaskExternalOperationProviderLifecycleService.returnProviderRunToMonitoring(
            operation: operation,
            task: task,
            run: run,
            modelContext: modelContext,
            at: run.completedAt ?? Date()
        )
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
