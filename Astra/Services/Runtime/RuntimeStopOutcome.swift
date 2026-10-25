import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Commits a runtime stop and its structured repair evidence together.
/// New stops never derive an authentication action from display prose.
@MainActor
enum RuntimeStopOutcome {
    @MainActor
    static func apply(
        _ result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) -> Bool {
        guard let reason = result.runtimeStopReason, !reason.isEmpty else { return false }

        run.status = .failed
        run.typedStopReason = TaskRunStopReason.custom(reason)
        if AgentRuntimeWorker.isTerminalRuntimeStop(reason) {
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
        } else {
            TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext)
        }

        let captured = result.runtimeRepairContext ?? (reason == TaskRunStopReason.capabilitySessionExpired.rawValue
            ? RuntimeRepairContext.manualReview(message: result.runtimeStopMessage ?? "Authentication needs manual review.") : nil)
        let repairContext = captured.map {
            RuntimeRepairContextResolver.resolve($0, environment: TaskLifecycleCoordinator.projectedCheckEnvironment(for: task, binary: $0.providerBinary))
        }
        let payload = repairContext?.message ?? result.runtimeStopMessage
            ?? "ASTRA stopped the provider because a runtime guardrail was reached: \(reason)."
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run))
        if let repairContext {
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeRepairContext,
                                          payload: repairContext.encoded(), run: run))
            if repairContext.offersAction {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeRepairRequired,
                                              payload: repairContext.repair.encoded(), run: run))
            }
        }
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "phase": phase.rawValue,
            "reason": reason,
            "source": "runtime_stop"
        ], level: .error)
        return true
    }

}
