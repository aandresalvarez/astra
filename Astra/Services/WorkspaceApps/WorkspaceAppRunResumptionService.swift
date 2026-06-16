import Foundation
import SwiftData

// B2: bridges async agent-task completion back to a suspended workflow run.
// Given a completed task, it finds the waiting `WorkspaceAppRun`s linked to that
// task, loads each app's manifest, and resumes the pipeline from its saved step
// (binding the task's output forward). The live call site — subscribing to task
// completion in the runtime — calls `resumeRuns(awaitingTaskID:...)`.
struct WorkspaceAppRunResumptionService {
    var executor = WorkspaceAppActionExecutor()

    @MainActor
    @discardableResult
    func resumeRuns(
        awaitingTaskID taskID: UUID,
        taskOutputRows: [[String: WorkspaceAppStorageValue]] = [],
        workspace: Workspace,
        modelContext: ModelContext
    ) -> [WorkspaceAppActionExecutionResult] {
        let waitingRuns = ((try? modelContext.fetch(FetchDescriptor<WorkspaceAppRun>())) ?? [])
            .filter { $0.status == .waiting && $0.linkedTaskID == taskID && $0.workspaceID == workspace.id }

        var results: [WorkspaceAppActionExecutionResult] = []
        for run in waitingRuns {
            guard let app = workspaceApp(id: run.appID, modelContext: modelContext),
                  let manifest = manifest(for: app, workspace: workspace) else {
                continue
            }
            if let result = try? executor.resume(
                run: run,
                app: app,
                workspace: workspace,
                manifest: manifest,
                taskOutputRows: taskOutputRows,
                modelContext: modelContext
            ) {
                results.append(result)
            }
        }
        return results
    }

    @MainActor
    private func workspaceApp(id: UUID, modelContext: ModelContext) -> WorkspaceApp? {
        ((try? modelContext.fetch(FetchDescriptor<WorkspaceApp>())) ?? []).first { $0.id == id }
    }

    private func manifest(for app: WorkspaceApp, workspace: Workspace) -> WorkspaceAppManifest? {
        let url = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
    }
}
