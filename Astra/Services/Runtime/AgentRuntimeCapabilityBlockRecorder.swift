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

    @MainActor
    static func apply(
        _ block: TaskRuntimeCompatibilityLaunchBlock,
        runtime: AgentRuntimeID,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        selectedRuntimeEvidence: [String] = []
    ) {
        run.status = .failed
        run.completedAt = Date()
        run.typedStopReason = TaskRunStopReason.custom(block.stopReason)
        TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext, at: run.completedAt ?? Date())
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskEventTypes.System.error.rawValue,
            payload: compatibilityEventPayload(block, runtime: runtime, evidence: selectedRuntimeEvidence),
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
            "reason": block.stopReason,
            "phase": phase.rawValue,
            "runtime": runtime.rawValue,
            "missing_capabilities": block.missingCapabilities.joined(separator: ","),
            "selected_runtime_evidence": selectedRuntimeEvidence.joined(separator: ",")
        ], level: .warning)
    }

    private static func compatibilityEventPayload(
        _ block: TaskRuntimeCompatibilityLaunchBlock,
        runtime: AgentRuntimeID,
        evidence: [String]
    ) -> String {
        let evidenceLine = evidence.isEmpty
            ? ""
            : "\n- Selected runtime evidence: \(evidence.joined(separator: ", "))"
        return """
        Selected runtime is incompatible with required ASTRA capabilities.
        - \(block.title): \(block.message) Remediation: \(block.remediation)
        - Runtime: \(runtime.displayName)
        - Missing capabilities: \(block.missingCapabilities.joined(separator: ", "))\(evidenceLine)
        """
    }
}
