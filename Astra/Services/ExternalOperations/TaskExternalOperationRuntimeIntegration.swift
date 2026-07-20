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
            // Every locally-owned, still-executing registration holds its root.
            // This includes `.stopped` rows: stopping MONITORING leaves the
            // detached job running (the confirmation says so), so its root must
            // stay excluded. Only imported no-contact rows (`.quarantined`) and
            // rows whose execution already terminated (job stopped writing) are
            // excluded.
            let holding = operations.filter {
                $0.monitoringState != .quarantined && !$0.executionState.isTerminalObservation
            }
            guard !holding.isEmpty else { return [] }
            let tasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
            let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return holding.compactMap { operation in
                guard let task = tasksByID[operation.taskID] else { return nil }
                return (resourceKey: taskQueue.resourceKey(for: task), taskID: operation.taskID, operationID: operation.id)
            }
        }
    }

    func startExternalOperationMonitoring(modelContext: ModelContext) {
        installExternalOperationResourceHolders(modelContext: modelContext)
        if let externalOperationMonitor {
            externalOperationMonitor.start()
            return
        }

        // Adopt trusted records before the first due-poll calculation. This is
        // read-only with respect to the executor and never launches a job.
        let tasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
        for task in tasks {
            TaskExternalOperationRegistrationService.reconcileTrustedBackendRecords(
                task: task,
                modelContext: modelContext
            )
        }
        if modelContext.hasChanges {
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: nil,
                modelContext: modelContext,
                auditFields: ["operation": "external_operation_startup_adoption"]
            )
        }

        let dockerBackend = WorkspaceManagedJobExternalOperationBackend(modelContext: modelContext)
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
                return true
            }
            // A wake for a still-nonterminal observation (an ambiguity-
            // reasoning wake) runs while the detached job may still be writing
            // the execution root — its own registration row is still a durable
            // resource holder. Admit that session as a READER only: the
            // resource-lock bypass for a claim's own operation is restricted to
            // read claims, so a write claim here would deadlock against the
            // operation's own holder, and a write admission would let the
            // reasoning session race the detached job's writes. Terminal wakes
            // (validation/reasoning after the job stopped) keep write access.
            return await taskQueue.continueSession(
                task: task,
                message: TaskExternalOperationWakeMessageRenderer.render(request),
                modelContext: modelContext,
                executionPolicy: .externalOperationWake(operationID: request.operationID),
                resourceAccess: request.observation.executionState.isTerminalObservation ? .write : .readOnly
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
