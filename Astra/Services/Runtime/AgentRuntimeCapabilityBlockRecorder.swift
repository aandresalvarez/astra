import Foundation
import SwiftData
import ASTRACore

enum AgentRuntimeCapabilityBlockRecorder {
    @MainActor
    static func apply(
        _ block: AgentRuntimeCapabilityCompatibilityPolicy.LaunchBlock,
        runtime: AgentRuntimeID,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) {
        run.status = .failed
        run.completedAt = Date()
        run.typedStopReason = block.stopReason
        TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext, at: run.completedAt ?? Date())
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskEventTypes.System.error.rawValue,
            payload: block.eventPayload,
            run: run
        ))
        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: modelContext)
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: AgentRuntimeRunPersistence.fields(task: task, run: run, phase: phase)
        )
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "reason": block.stopReason.rawValue,
            "phase": phase.rawValue,
            "runtime": runtime.rawValue,
            "required_host_control_tools": block.requiredTools.joined(separator: ",")
        ], level: .warning)
    }
}
