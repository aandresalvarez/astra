import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

protocol DockerImageRecoveryEventRecording {
    @discardableResult
    @MainActor
    func record(
        task: AgentTask,
        run: TaskRun?,
        plan: DockerImageRecoveryPlan,
        result: DockerImageRecoveryEventPayload.Result,
        detail: String?,
        operationID: UUID?,
        verifiedImageID: String?,
        modelContext: ModelContext
    ) -> Bool
}

struct DockerImageRecoveryEventRecorder: DockerImageRecoveryEventRecording {
    @discardableResult
    @MainActor
    func record(
        task: AgentTask,
        run: TaskRun?,
        plan: DockerImageRecoveryPlan,
        result: DockerImageRecoveryEventPayload.Result,
        detail: String?,
        operationID: UUID?,
        verifiedImageID: String?,
        modelContext: ModelContext
    ) -> Bool {
        let imageID: String?
        if let verifiedImageID {
            imageID = verifiedImageID
        } else if case .retag(let value) = plan.action {
            imageID = value
        } else {
            imageID = nil
        }
        let event = TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.System.dockerImageRecovery,
            payload: DockerImageRecoveryEventPayload(
                operationID: operationID,
                image: plan.image,
                action: plan.auditAction,
                result: result,
                imageID: imageID,
                detail: detail,
                dockerfilePath: plan.authorizedDockerfilePath.map(WorkspacePathPresentation.standardizedPath),
                sourcePath: plan.authorizedSourcePath.map(WorkspacePathPresentation.standardizedPath)
            ),
            run: run
        )
        modelContext.insert(event)
        let persisted = WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "docker_image_recovery", "recovery_result": result.rawValue]
        )
        guard persisted else {
            // Never let an in-memory event masquerade as durable authorization
            // or durable success after its save failed.
            modelContext.delete(event)
            AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", taskID: task.id, fields: [
                "result": "recovery_event_persistence_failed",
                "image": plan.image,
                "recovery_action": plan.auditAction,
                "recovery_result": result.rawValue
            ], level: .error)
            return false
        }
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", taskID: task.id, fields: [
            "result": "recovery_\(result.rawValue)",
            "image": plan.image,
            "recovery_action": plan.auditAction,
            "detail": detail ?? "none"
        ], level: result == .failed ? .error : .info)
        return true
    }
}
