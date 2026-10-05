import SwiftData
import ASTRAModels

extension TaskExecutionContext {
    @MainActor
    func prepareValidation(task: AgentTask, modelContext: ModelContext) -> TaskValidationContractEvaluation? {
        do {
            try bindStorage(task: task, modelContext: modelContext)
            return nil
        } catch {
            let summary = "Validation authority is invalid: \(error.localizedDescription)"
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: summary))
            AppLogger.audit(.validationFailed, category: "Validation", taskID: task.id,
                fields: ["reason": "invalid_execution_context", "error": error.localizedDescription], level: .error)
            return .init(didRun: true, outcome: .failed, canComplete: false,
                summary: summary, failedRequiredAssertionIDs: [])
        }
    }
}
