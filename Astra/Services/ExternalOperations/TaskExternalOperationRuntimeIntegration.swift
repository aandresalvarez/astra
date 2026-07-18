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
        Originating run: \(request.originatingRunID.uuidString)
        Originating context revision (provenance only): \(provenance)

        Use the latest Context Capsule below as the current task truth. Do not relaunch or duplicate the external operation. Process completion is not task success: validate the task outcome before declaring success.

        \(request.latestContext)
        """
    }
}

@MainActor
extension AppRuntimeController {
    func startExternalOperationMonitoring(modelContext: ModelContext) {
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
            guard TaskExternalOperationWakeAdmission.shouldResume(taskStatus: task.status) else { return true }
            return await taskQueue.continueSession(
                task: task,
                message: TaskExternalOperationWakeMessageRenderer.render(request),
                modelContext: modelContext,
                executionPolicy: .externalOperationWake
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
