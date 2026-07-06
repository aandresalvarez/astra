import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

enum AgentRuntimeStartAdmission {
    @MainActor
    static func confirmRuntimeSessionStarted(
        task: AgentTask,
        modelContext: ModelContext,
        auditPhase: RunPhase
    ) -> Bool {
        let result = TaskStateMachine.markRuntimeSessionStarted(task, modelContext: modelContext)
        guard result.rejection == nil else {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "reason": "runtime_start_rejected",
                "phase": auditPhase.rawValue,
                "from": result.from.rawValue,
                "to": result.to.rawValue
            ], level: .warning)
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "Runtime start was rejected because this task was not admitted by the queue. Current status: \(result.from.rawValue)."
            ))
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: [
                    "operation": "runtime_start_rejected",
                    "phase": auditPhase.rawValue,
                    "status": result.from.rawValue
                ]
            )
            return false
        }
        return true
    }
}
