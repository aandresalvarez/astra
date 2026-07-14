import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Captures and durably owns the repository state that predates a provider
/// run. Typed publication is path-granular, so an already-dirty path must stay
/// outside its authority even when the provider later edits the same file.
enum TaskGitPublicationWorkspaceBaselineService {
    @MainActor
    static func capture(
        task: AgentTask,
        run: TaskRun,
        workspacePath: String,
        modelContext: ModelContext
    ) -> Set<String>? {
        // Every provider can emit structured file changes, so this boundary is
        // deliberately independent of runtime-specific inference support.
        let gitStatus = AgentFileChangeDetector.gitStatusSnapshot(workspacePath: workspacePath)
        guard let baseline = AgentFileChangeDetector.publicationWorkspaceBaseline(
            runID: run.id,
            workspacePath: workspacePath,
            beforeGitStatus: gitStatus
        ) else { return gitStatus }

        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationWorkspaceBaseline,
            payload: baseline,
            run: run
        ))
        do {
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "git_publish_workspace_baseline"]
            )
            return gitStatus
        } catch {
            run.recordCompletionBlocked(stopReason: .policyBlocked)
            run.completedAt = Date()
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: run.completedAt ?? Date())
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "ASTRA could not durably record the repository's pre-run dirty state, so the provider was not launched.",
                run: run
            ))
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "git_publish_workspace_baseline_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }
}
