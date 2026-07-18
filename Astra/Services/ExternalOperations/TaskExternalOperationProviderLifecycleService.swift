import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Detaches provider-run lifecycle from task-owned external work.
///
/// A trusted registration is the ownership boundary: once committed, provider
/// exit classification must not make the task retryable while the same
/// external job is still registered. Explicit task cancellation remains
/// authoritative and never cancels the backend job implicitly.
@MainActor
enum TaskExternalOperationProviderLifecycleService {
    @discardableResult
    static func beginMonitoringAtRegistration(
        operation: TaskExternalOperation,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        at date: Date = Date()
    ) -> Bool {
        applyMonitoringState(
            operation: operation,
            task: task,
            run: run,
            requireOriginatingRun: true,
            modelContext: modelContext,
            at: date
        )
    }

    /// Returns a fresh validation or reasoning run to deterministic monitoring
    /// when another run still owns unfinished external work for the same task.
    @discardableResult
    static func returnProviderRunToMonitoring(
        operation: TaskExternalOperation,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        at date: Date = Date()
    ) -> Bool {
        applyMonitoringState(
            operation: operation,
            task: task,
            run: run,
            requireOriginatingRun: false,
            modelContext: modelContext,
            at: date
        )
    }

    private static func applyMonitoringState(
        operation: TaskExternalOperation,
        task: AgentTask,
        run: TaskRun,
        requireOriginatingRun: Bool,
        modelContext: ModelContext,
        at date: Date
    ) -> Bool {
        guard operation.taskID == task.id,
              run.task?.id == task.id,
              (!requireOriginatingRun || operation.originatingRunID == run.id),
              task.status != .cancelled,
              [.active, .validating, .completed].contains(operation.monitoringState) else {
            return false
        }

        run.completedAt = run.completedAt ?? date
        run.recordExternalOutcomePending()
        let transition = TaskStateMachine.pauseForMonitoredExternalOperation(
            task,
            modelContext: modelContext,
            at: date
        )
        guard transition.rejection == nil else { return false }

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

        AppLogger.audit(.taskStarted, category: "ExternalOperation", taskID: task.id, fields: [
            "operation": "provider_detached",
            "backend": operation.backendKindRaw,
            "originating_run_id": run.id.uuidString
        ])
        return true
    }

    /// Coalesces every non-cancellation provider exit behind the durable
    /// registration. This is intentionally checked before timeout, budget,
    /// runtime-failure, and validation branches in the worker.
    @discardableResult
    static func preserveMonitoringAfterProviderExitIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        at date: Date = Date()
    ) -> Bool {
        guard let operation = TaskExternalOperationRegistrationService.operations(
            taskID: task.id,
            modelContext: modelContext
        ).first(where: {
            $0.originatingRunID == run.id
                && [.active, .validating, .completed].contains($0.monitoringState)
        }) else {
            return false
        }
        return beginMonitoringAtRegistration(
            operation: operation,
            task: task,
            run: run,
            modelContext: modelContext,
            at: date
        )
    }

    /// Failure-path counterpart to `preserveMonitoringAfterProviderExitIfNeeded`.
    ///
    /// A wake or validation run always carries a fresh run id, so the
    /// originating-run guard above never matches it. Without this, a failed wake
    /// run (timeout, budget, runtime failure, policy violation) would terminalize
    /// a task whose external operation is still `.active`/`.validating`, exposing
    /// a retry that duplicates the live job — and because the wake was already
    /// acknowledged, terminal reconciliation would not re-fire, stranding the
    /// task. The success path already returns such runs to monitoring
    /// (`TaskSuccessfulCompletionService`); this mirrors it for the failure
    /// branches. Deliberately excludes the originating run so a genuinely failed
    /// original launch (whose op is not active/validating) still terminalizes.
    @discardableResult
    static func returnFailedWakeRunToMonitoringIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        at date: Date = Date()
    ) -> Bool {
        guard let operation = TaskExternalOperationRegistrationService.operations(
            taskID: task.id,
            modelContext: modelContext
        ).first(where: {
            $0.originatingRunID != run.id
                && [.active, .validating].contains($0.monitoringState)
        }) else {
            return false
        }
        return returnProviderRunToMonitoring(
            operation: operation,
            task: task,
            run: run,
            modelContext: modelContext,
            at: date
        )
    }
}
