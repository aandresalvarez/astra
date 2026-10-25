import Foundation
import SwiftData
import ASTRAModels

/// Cancellation wins at each outcome commit boundary, including validation
/// that returns after the provider itself has already finished successfully.
@MainActor
enum RuntimeSettlementCancellation {
    static func isCancelled(_ task: AgentTask) -> Bool {
        Task.isCancelled || task.status == .cancelled || RuntimeSettlementExecutionScope.current?.isCancelled == true
    }

    @discardableResult
    static func applyIfNeeded(task: AgentTask, run: TaskRun, context: ModelContext) -> Bool {
        guard isCancelled(task) else { return false }
        run.status = .cancelled
        run.typedStopReason = .cancelled
        TaskStateMachine.cancelFromRuntime(task, modelContext: context)
        return true
    }
}
