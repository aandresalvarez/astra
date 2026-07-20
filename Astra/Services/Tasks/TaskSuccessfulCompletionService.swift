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

        // Does THIS run correspond to a terminal-failure operation's own
        // reasoning wake (or is it that operation's originating run)? If a
        // reasoning wake, its `externalOperation.review.required` event must
        // be recorded NOW, unconditionally — independent of whether some
        // OTHER operation is still active — or the wake sink
        // (`wakeOutcomeResolved`) can never acknowledge it and terminal
        // reconciliation retries this already-succeeded reasoning wake
        // forever. Recorded before the active/validating check below so a
        // still-pending sibling operation cannot suppress it.
        var ownFailureOperationRequiringPendingReview: TaskExternalOperation?
        if let failureOperation = operations.first(where: {
            // A stale `.completed` terminal-failure row is otherwise never
            // cleared, so without the ID gate here ANY future successful run
            // on this task — including ones with nothing to do with this
            // operation — would re-enter "review required" forever. Only the
            // run that produced the failure, or the run dispatched as ITS OWN
            // reasoning wake, may match.
            $0.monitoringState == .completed
                && $0.executionState.isTerminalObservation
                && $0.executionState != .processCompleted
                && ($0.originatingRunID == run.id || $0.id == validatingOperationID)
        }) {
            if failureOperation.originatingRunID == run.id {
                // The originating provider turn cannot convert an already
                // terminal external failure into task success. Keep the task
                // waiting until the operation-specific reasoning wake runs.
                pauseForMonitoring(operation: failureOperation, task: task, run: run, modelContext: modelContext)
                return false
            }
            // A reasoning wake may explain cancellation/failure/interruption,
            // but successful narration is not successful external work.
            let operationID = failureOperation.id.uuidString
            let alreadyRecorded = task.events.contains {
                $0.type == "externalOperation.review.required" && $0.payload.contains(operationID)
            }
            if !alreadyRecorded {
                modelContext.insert(TaskEvent(
                    task: task,
                    type: "externalOperation.review.required",
                    payload: TaskEvent.payloadString([
                        "execution_state": failureOperation.executionState.rawValue,
                        "operation_id": operationID
                    ]),
                    run: run
                ))
            }
            ownFailureOperationRequiringPendingReview = failureOperation
        }

        // Completing one validation (or recording the review event just
        // above) never supersedes another task-owned operation. Re-evaluate
        // the full set so a remaining active, validating, or
        // stopped-but-still-executing row keeps the task waitingExternal
        // ("Stop monitoring" leaves the external job running, so it must not
        // unlock task completion) — including when THIS run was itself a
        // reasoning wake whose review event is now durably recorded but a
        // SIBLING operation is still live.
        if let operation = operations.first(where: {
            $0.monitoringState == .active || $0.monitoringState == .validating
                || ($0.monitoringState == .stopped && !$0.executionState.isTerminalObservation)
        }) {
            // An ambiguity/reasoning wake does not supersede the still-running
            // external operation. A successful explanatory provider turn
            // returns the task to durable monitoring.
            pauseForMonitoring(operation: operation, task: task, run: run, modelContext: modelContext)
            return false
        }

        if ownFailureOperationRequiringPendingReview != nil {
            let completedAt = run.completedAt ?? Date()
            run.completedAt = completedAt
            run.recordExternalOutcomePending()
            TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext, at: completedAt)
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
    ///
    /// `task.approved` carries no operation-specific identity (it is one
    /// generic UI action), so with TWO failed operations whose reasoning
    /// wakes are serialized, each inserts its own `review.required` event and
    /// a single approval click could otherwise satisfy BOTH — even though the
    /// user only ever saw and approved whichever failure's review was most
    /// recently surfaced. An approval is credited to an operation only when
    /// that operation's `review.required` event is the LATEST one at the
    /// moment of approval — i.e. no OTHER operation's review surfaced in
    /// between and could have been the one actually being approved.
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
        return task.events.contains { approval in
            guard approval.type == TaskEventTypes.Task.approved.rawValue,
                  approval.timestamp >= reviewRequiredAt else { return false }
            let laterUnrelatedReviewIntervened = task.events.contains {
                $0.type == "externalOperation.review.required"
                    && !$0.payload.contains(operationID)
                    && $0.timestamp > reviewRequiredAt
                    && $0.timestamp <= approval.timestamp
            }
            return !laterUnrelatedReviewIntervened
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
