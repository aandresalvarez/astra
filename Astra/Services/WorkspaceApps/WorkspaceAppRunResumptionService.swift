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
        consumedTokens: Int = 0,
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
                consumedTokens: consumedTokens,
                modelContext: modelContext
            ) {
                results.append(result)
            }
        }
        return results
    }

    // B2-live: sweep for waiting runs whose linked agent task has finished and
    // resume them. Called after the task queue runs and when a workspace opens, so
    // a workflow resumes both in-session and across sessions (the task may have
    // completed while the app was closed).
    @MainActor
    @discardableResult
    func resumeCompletedRuns(modelContext: ModelContext) -> [WorkspaceAppActionExecutionResult] {
        let waitingRuns = ((try? modelContext.fetch(FetchDescriptor<WorkspaceAppRun>())) ?? [])
            .filter { $0.status == .waiting }

        var results: [WorkspaceAppActionExecutionResult] = []
        for run in waitingRuns {
            // C1 barrier: a fanned-out run awaits a SET of tasks; a B2 single-task run
            // is the degenerate one-element set (via linkedTaskID). Resume only when
            // EVERY awaited task has completed, re-derived authoritatively from the store.
            let barrier = barrierTaskIDs(for: run)
            guard !barrier.isEmpty else { continue }
            let tasks = barrier.compactMap { agentTask(id: $0, modelContext: modelContext) }
            guard tasks.count == barrier.count,
                  tasks.allSatisfy({ $0.status == .completed }),
                  let workspace = workspace(id: run.workspaceID, modelContext: modelContext),
                  let app = workspaceApp(id: run.appID, modelContext: modelContext),
                  let manifest = manifest(for: app, workspace: workspace) else {
                continue
            }
            let outputRows = tasks.map { taskOutputRow(for: $0) }
            let consumed = tasks.reduce(0) { $0 + consumedTokens(for: $1) }
            if let result = try? executor.resume(
                run: run,
                app: app,
                workspace: workspace,
                manifest: manifest,
                taskOutputRows: outputRows,
                consumedTokens: consumed,
                modelContext: modelContext
            ) {
                results.append(result)
            }
        }
        return results
    }

    private func barrierTaskIDs(for run: WorkspaceAppRun) -> [UUID] {
        run.awaitedTaskIDs.isEmpty ? (run.linkedTaskID.map { [$0] } ?? []) : run.awaitedTaskIDs
    }

    private func consumedTokens(for task: AgentTask) -> Int {
        task.runs.reduce(0) { $0 + $1.outputTokens }
    }

    @MainActor
    private func workspace(id: UUID, modelContext: ModelContext) -> Workspace? {
        ((try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []).first { $0.id == id }
    }

    private func taskOutputRow(for task: AgentTask) -> [String: WorkspaceAppStorageValue] {
        [
            "task_id": .text(task.id.uuidString),
            "status": .text(task.status.rawValue),
            "title": .text(task.title)
        ]
    }

    @MainActor
    private func agentTask(id: UUID, modelContext: ModelContext) -> AgentTask? {
        ((try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []).first { $0.id == id }
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
