import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct TaskQueueExternalOperationWakeSink: TaskExternalOperationWakeSinking, @unchecked Sendable {
    let action: @MainActor @Sendable (TaskExternalOperationWakeRequest) async -> Bool

    func wake(_ request: TaskExternalOperationWakeRequest) async -> Bool {
        await action(request)
    }
}

/// Decides whether a terminal external-operation wake may resume a task.
///
/// Monitoring intentionally continues after a user cancellation (so the terminal
/// observation is still recorded and notified), but `continueSession` →
/// `admitContinuationToRuntime` admits from any non-draft status — including
/// `.cancelled` — so delivering the wake would silently flip an explicitly
/// cancelled task back to `.running`. Extracted so the invariant is unit-tested.
enum TaskExternalOperationWakeAdmission {
    static func shouldResume(taskStatus: TaskStatus) -> Bool {
        taskStatus != .cancelled
    }

    /// Whether a delivered terminal wake actually achieved its outcome.
    ///
    /// `TaskQueue.continueSession` returns `true` whenever the worker RAN — but
    /// the worker can exit early after admission (missing provider executable,
    /// runtime/connector/Docker/isolation preflight failure) without touching
    /// the operation. Acknowledging such a wake would permanently strand it:
    /// terminal reconciliation only retries UNacknowledged deliveries. The sink
    /// therefore acknowledges only when the wake's observable outcome exists;
    /// otherwise the wake stays pending and retries on a later scheduler pass.
    static func wakeOutcomeResolved(
        intent: TaskExternalOperationWakeIntent,
        operationMonitoringState: TaskExternalOperationMonitoringState?,
        taskStatus: TaskStatus,
        hasOperationReviewEvent: Bool = false
    ) -> Bool {
        switch intent {
        case .completionValidation:
            // Resolved when the validating state was consumed (operation
            // `.completed`, or the row vanished) or the task terminalized.
            // A failed validation run leaves `.validating` + `waitingExternal`
            // on purpose — unresolved, so the wake retries.
            return operationMonitoringState != .validating || taskStatus == .completed
        case .userFacingReasoning:
            // Resolved only by the OPERATION-SPECIFIC durable review event
            // (or a completion racing this wake). `.pendingUser` alone is not
            // proof: preflight gates (e.g. a policy-manifest launch block) can
            // park the task in runtime review before any provider session ran
            // or the external review was ever written — that wake must retry.
            return hasOperationReviewEvent || taskStatus == .completed
        case .ambiguousObservation:
            // Never launches a provider session (suppressed at the sink while
            // the observation is nonterminal); acknowledged unconditionally.
            return true
        }
    }
}

struct TaskEventExternalOperationNotificationSink:
    TaskExternalOperationNotificationSinking,
    @unchecked Sendable
{
    let action: @MainActor @Sendable (TaskExternalOperationNotification) async -> Bool

    func notify(_ notification: TaskExternalOperationNotification) async -> Bool {
        await action(notification)
    }
}

enum TaskExternalOperationWakeMessageRenderer {
    static func render(_ request: TaskExternalOperationWakeRequest) -> String {
        let provenance = request.originatingContextRevision ?? "unavailable"
        return """
        ASTRA external-operation observation

        Intent: \(request.intent.rawValue)
        Execution state: \(request.observation.executionState.rawValue)
        Observation health: \(request.observation.health.rawValue)
        Backend job ID: \(request.backendJobID)
        Originating run: \(request.originatingRunID.uuidString)
        Originating context revision (provenance only): \(provenance)

        Use the workspace job status/tail/wait tools with the backend job ID above to inspect this job's logs and result. Use the latest Context Capsule below as the current task truth. Do not relaunch or duplicate the external operation. Process completion is not task success: validate the task outcome before declaring success.

        \(request.latestContext)
        """
    }
}

@MainActor
extension AppRuntimeController {
    /// Wires the resource-lock exclusion provider so admission derives exclusion
    /// from durable external-operation rows (in-memory locks are empty after a
    /// restart). Installed BEFORE the scheduler starts — otherwise a due task
    /// could acquire an overlapping execution root on launch before this runs.
    func installExternalOperationResourceHolders(modelContext: ModelContext) {
        taskQueue.externalOperationResourceHolders = { [weak taskQueue] in
            guard let taskQueue else { return [] }
            let operations = (try? modelContext.fetch(FetchDescriptor<TaskExternalOperation>())) ?? []
            // Every locally-owned, still-executing registration holds its root
            // (including `.stopped` rows: stopping MONITORING leaves the
            // detached job running). A TERMINAL registration keeps holding it
            // while its validation/reasoning wake is still pending — releasing
            // the root the moment the job stops would let a waiting task
            // mutate or remove the job's outputs before the wake validates
            // them. Only imported no-contact rows (`.quarantined`) and fully
            // delivered terminal rows are excluded.
            let holding = operations.filter {
                guard $0.monitoringState != .quarantined else { return false }
                return !$0.executionState.isTerminalObservation
                    || TaskExternalOperationWakeKeyDerivation.hasPendingTerminalWake($0)
            }
            guard !holding.isEmpty else { return [] }
            let tasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
            let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return holding.compactMap { operation in
                guard let task = tasksByID[operation.taskID] else { return nil }
                // Prefer the LAUNCH-TIME root persisted at registration; the
                // task/workspace-derived key is user-mutable while the
                // detached job keeps writing the root it actually mounted.
                let resourceKey = operation.launchResourceKey ?? taskQueue.resourceKey(for: task)
                return (
                    resourceKey: resourceKey,
                    taskID: operation.taskID,
                    operationID: operation.id,
                    allowsSameOperationWrite: operation.executionState.isTerminalObservation
                )
            }
        }
    }

    /// Adopts trusted backend receipts into durable registrations. Idempotent;
    /// read-only with respect to the executor and never launches a job. MUST
    /// run before any scheduler that can admit workspace work: after a crash
    /// in the launch-to-registration window there is deliberately no operation
    /// row yet, so holder installation alone cannot exclude the job's root —
    /// only adoption creates the missing holder.
    func adoptTrustedExternalOperationReceipts(modelContext: ModelContext) {
        let tasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
        for task in tasks {
            TaskExternalOperationRegistrationService.reconcileTrustedBackendRecords(
                task: task,
                modelContext: modelContext,
                // Startup-only path: no provider session is live yet, so a job
                // that terminalized while ASTRA was down can release its
                // crash-left executor container (terminal rows are never
                // polled, so the backend observe-path cleanup never runs).
                cleanupTerminalExecutors: true
            )
        }
        if modelContext.hasChanges {
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: nil,
                modelContext: modelContext,
                auditFields: ["operation": "external_operation_startup_adoption"]
            )
        }
    }

    func startExternalOperationMonitoring(modelContext: ModelContext) {
        installExternalOperationResourceHolders(modelContext: modelContext)
        if let externalOperationMonitor {
            externalOperationMonitor.start()
            return
        }

        // Adopt trusted records before the first due-poll calculation (a
        // second, idempotent pass — the pre-scheduler startup step already ran
        // one so crash-window jobs are excluded before any schedule fires).
        adoptTrustedExternalOperationReceipts(modelContext: modelContext)

        let dockerBackend = WorkspaceManagedJobExternalOperationBackend(
            modelContext: modelContext,
            // Live worker state, not durable run status: registration finalizes
            // the originating run to `.completed` while the provider turn is
            // still connected and issuing workspace_shell calls in the shared
            // executor container. Scoped to the EXACT run (not just "any
            // worker busy for this task") since container names are
            // run-scoped: a newer run's active worker must not block cleanup
            // of an older, unrelated run's already-idle container.
            providerSessionActive: { [weak taskQueue] taskID, originatingRunID in
                taskQueue?.taskWorkerMap[taskID]?.currentRunID == originatingRunID
            }
        )
        let backend = TaskExternalOperationBackendRouter(registry: .init([
            (kind: WorkspaceManagedJobStartReceipt.backend, backend: dockerBackend)
        ]))
#if canImport(UserNotifications)
        let systemNotificationDelivery: any TaskExternalOperationSystemNotificationDelivering =
            UserNotificationCenterExternalOperationDelivery()
#else
        let systemNotificationDelivery: any TaskExternalOperationSystemNotificationDelivering =
            NoopTaskExternalOperationSystemNotificationDelivery()
#endif
        let wakeSink = TaskQueueExternalOperationWakeSink { [taskQueue] request in
            let taskID = request.taskID
            var descriptor = FetchDescriptor<AgentTask>(
                predicate: #Predicate<AgentTask> { $0.id == taskID }
            )
            descriptor.fetchLimit = 1
            guard let task = try? modelContext.fetch(descriptor).first else { return false }
            // A wake for a still-NONTERMINAL observation (ambiguity) is never
            // allowed to launch a provider session: `resourceAccess` terminates
            // in lock admission and is not enforced by the provider policy or
            // sandbox, so a "read-only" reasoning session could still mutate
            // the execution root the detached job is writing, or cancel and
            // relaunch jobs. The user is informed through the notification
            // sink; provider reasoning is deferred until the observation is
            // terminal (the lock-side read-only restriction stays as defense
            // in depth). Acknowledge so the same incident is not redelivered;
            // `apply` re-arms the wake key on the next healthy observation.
            guard request.observation.executionState.isTerminalObservation else {
                return true
            }
            // Never resurrect an explicitly cancelled task. Return true so the
            // wake is acknowledged and not retried, while the task stays cancelled.
            guard TaskExternalOperationWakeAdmission.shouldResume(taskStatus: task.status) else {
                // The suppressed wake is the operation's ONLY path out of
                // `.validating`/`.active` (terminal reconciliation only retries
                // UNacknowledged deliveries). Finalize it here or the row is
                // orphaned forever: the UI shows "ASTRA is validating" forever,
                // and TaskSuccessfulCompletionService's active/validating check
                // then silently re-parks every future unrelated successful run
                // on this task back into waitingExternal.
                let operationID = request.operationID
                var operationDescriptor = FetchDescriptor<TaskExternalOperation>(
                    predicate: #Predicate<TaskExternalOperation> { $0.id == operationID }
                )
                operationDescriptor.fetchLimit = 1
                if let operation = try? modelContext.fetch(operationDescriptor).first,
                   operation.monitoringState != .completed {
                    operation.monitoringState = .completed
                    operation.nextCheckAt = nil
                    operation.updatedAt = Date()
                    WorkspacePersistenceCoordinator.saveAndAutoExport(
                        workspace: task.workspace,
                        modelContext: modelContext,
                        taskID: task.id,
                        auditFields: ["operation": "external_operation_wake_suppressed_cancelled"]
                    )
                }
                // This suppression bypasses AgentRuntimeWorker — the only code
                // that cleans the isolation retained when the provider
                // detached. Without cleanup here, a cancelled `.gitBranch`
                // task's repository stays checked out on its astra/* branch
                // (and a `.copy` task's copy directory persists) forever, and
                // later tasks acquire the workspace on the wrong branch. Clean
                // up once no other nonterminal operation still uses the root.
                let operations = (try? modelContext.fetch(FetchDescriptor<TaskExternalOperation>())) ?? []
                let rootStillInUse = operations.contains {
                    $0.taskID == task.id
                        && $0.id != request.operationID
                        && $0.monitoringState != .quarantined
                        && !$0.executionState.isTerminalObservation
                }
                if !rootStillInUse {
                    // This specific operation's own launch root — not just
                    // "any retained root for the task" — since it is the one
                    // whose isolation was actually retained for this wake.
                    let launchRoot = TaskExternalOperationRegistrationService.launchExecutionRoot(
                        operationID: request.operationID,
                        modelContext: modelContext
                    )
                    if let retained = IsolationService.retainedExecutionPath(task: task, launchRootOverride: launchRoot) {
                        IsolationService.cleanup(task: task, executionPath: retained)
                    }
                }
                return true
            }
            let continued = await taskQueue.continueSession(
                task: task,
                message: TaskExternalOperationWakeMessageRenderer.render(request),
                modelContext: modelContext,
                executionPolicy: .externalOperationWake(operationID: request.operationID)
            )
            guard continued else { return false }
            // `continued` only proves the worker RAN — it can exit early after
            // admission (missing executable, runtime/connector/Docker/isolation
            // preflight) without ever touching the operation. Acknowledge only
            // when the wake's observable outcome exists; otherwise leave the
            // wake unacknowledged so terminal reconciliation retries it.
            let operationID = request.operationID
            var operationDescriptor = FetchDescriptor<TaskExternalOperation>(
                predicate: #Predicate<TaskExternalOperation> { $0.id == operationID }
            )
            operationDescriptor.fetchLimit = 1
            let operation = try? modelContext.fetch(operationDescriptor).first
            let operationIDString = request.operationID.uuidString
            let hasReviewEvent = task.events.contains {
                $0.type == "externalOperation.review.required" && $0.payload.contains(operationIDString)
            }
            return TaskExternalOperationWakeAdmission.wakeOutcomeResolved(
                intent: request.intent,
                operationMonitoringState: operation?.monitoringState,
                taskStatus: task.status,
                hasOperationReviewEvent: hasReviewEvent
            )
        }
        let notificationSink = TaskEventExternalOperationNotificationSink { notification in
            let taskID = notification.taskID
            var descriptor = FetchDescriptor<AgentTask>(
                predicate: #Predicate<AgentTask> { $0.id == taskID }
            )
            descriptor.fetchLimit = 1
            guard let task = try? modelContext.fetch(descriptor).first else { return false }
            modelContext.insert(TaskEvent(
                task: task,
                type: "externalOperation.observation.changed",
                payload: TaskEvent.payloadString([
                    "execution_state": notification.observation.executionState.rawValue,
                    "observation_health": notification.observation.health.rawValue,
                    "operation_id": notification.operationID.uuidString
                ])
            ))
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus()
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "external_operation_observation_event"]
            )
            await systemNotificationDelivery.deliver(notification)
            return true
        }
        let monitor = TaskExternalOperationMonitorService(
            modelContext: modelContext,
            observer: backend,
            canceller: backend,
            ownershipValidator: backend,
            wakeSink: wakeSink,
            notificationSink: notificationSink,
            contextProvider: { taskID in
                var descriptor = FetchDescriptor<AgentTask>(
                    predicate: #Predicate<AgentTask> { $0.id == taskID }
                )
                descriptor.fetchLimit = 1
                guard let task = try? modelContext.fetch(descriptor).first else { return "" }
                return TaskContextStateManager.refreshedPromptContext(for: task) ?? ""
            }
        )
        externalOperationMonitor = monitor
        monitor.start()
    }

    func stopExternalOperationMonitoring() {
        externalOperationMonitor?.stop()
    }
}
