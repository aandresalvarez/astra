import SwiftData
import ASTRAModels
import ASTRAPersistence

@MainActor
enum DockerImageRecoveryEventRecorder {
    static func record(
        task: AgentTask,
        run: TaskRun?,
        plan: DockerImageRecoveryPlan,
        result: DockerImageRecoveryEventPayload.Result,
        detail: String?,
        modelContext: ModelContext
    ) {
        let imageID: String?
        if case .retag(let value) = plan.action { imageID = value } else { imageID = nil }
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.System.dockerImageRecovery,
            payload: DockerImageRecoveryEventPayload(
                image: plan.image,
                action: plan.auditAction,
                result: result,
                imageID: imageID,
                detail: detail
            ),
            run: run
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", taskID: task.id, fields: [
            "result": "recovery_\(result.rawValue)",
            "image": plan.image,
            "recovery_action": plan.auditAction,
            "detail": detail ?? "none"
        ], level: result == .failed ? .error : .info)
    }
}
