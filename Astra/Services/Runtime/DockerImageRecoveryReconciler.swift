import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Closes durable recovery operations whose process continuation disappeared
/// during an ASTRA restart. A restart cannot prove whether Docker completed the
/// mutation, so the safe outcome is an explicit interrupted failure and no
/// automatic retry.
@MainActor
enum DockerImageRecoveryReconciler {
    private struct OperationKey: Hashable {
        var taskID: UUID
        var operationID: UUID?
        var runID: UUID?
        var image: String
        var action: String
    }

    @discardableResult
    static func reconcileInterruptedRecoveries(modelContext: ModelContext) -> Int {
        let events: [TaskEvent]
        do {
            events = try modelContext.fetch(FetchDescriptor<TaskEvent>())
        } catch {
            AppLogger.error("Docker recovery reconciliation could not read task events", category: "ExecutionEnvironment")
            return 0
        }

        let recoveryEvents = events.compactMap { event -> (TaskEvent, DockerImageRecoveryEventPayload)? in
            guard event.type == TaskEventTypes.System.dockerImageRecovery.rawValue,
                  let payload = try? event.decodePayload(
                    as: DockerImageRecoveryEventPayload.self,
                    expecting: TaskEventTypes.System.dockerImageRecovery
                  ).get() else { return nil }
            return (event, payload)
        }
        let terminalKeys: Set<OperationKey> = Set(recoveryEvents.compactMap { event, payload in
            guard payload.result != .started, let taskID = event.task?.id else { return nil }
            return key(taskID: taskID, event: event, payload: payload)
        })
        var knownTerminalKeys = terminalKeys
        var reconciled = 0

        for (startedEvent, startedPayload) in recoveryEvents where startedPayload.result == .started {
            guard let task = startedEvent.task else { continue }
            let operationKey = key(taskID: task.id, event: startedEvent, payload: startedPayload)
            guard !knownTerminalKeys.contains(operationKey) else { continue }

            var terminalPayload = startedPayload
            terminalPayload.result = .failed
            terminalPayload.detail = "Recovery was interrupted by an ASTRA restart; Docker completion is unknown and the task was not retried."
            let terminalEvent = TaskEvent.structuredPayloadEvent(
                task: task,
                eventType: TaskEventTypes.System.dockerImageRecovery,
                payload: terminalPayload,
                run: startedEvent.run
            )
            modelContext.insert(terminalEvent)
            let persisted = WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: [
                    "operation": "docker_image_recovery_reconciliation",
                    "recovery_result": DockerImageRecoveryEventPayload.Result.failed.rawValue
                ]
            )
            guard persisted else {
                modelContext.delete(terminalEvent)
                AppLogger.error(
                    "Docker recovery reconciliation could not durably record an interrupted operation",
                    category: "ExecutionEnvironment",
                    taskID: task.id
                )
                continue
            }
            knownTerminalKeys.insert(operationKey)
            reconciled += 1
        }

        return reconciled
    }

    private static func key(
        taskID: UUID,
        event: TaskEvent,
        payload: DockerImageRecoveryEventPayload
    ) -> OperationKey {
        OperationKey(
            taskID: taskID,
            operationID: payload.operationID,
            runID: event.run?.id,
            image: payload.image,
            action: payload.action
        )
    }
}
