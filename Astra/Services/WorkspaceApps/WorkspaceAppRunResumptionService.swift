import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

// B2: bridges async agent-task completion back to a suspended workflow run.
// Given a completed task, it finds the waiting `WorkspaceAppRun`s linked to that
// task, loads each app's manifest, and resumes the pipeline from its saved step
// (binding the task's output forward). The live call site — subscribing to task
// completion in the runtime — calls `resumeRuns(awaitingTaskID:...)`.
struct WorkspaceAppRunResumptionService {
    var executor = WorkspaceAppActionExecutor()
    var manifestStore = WorkspaceAppManifestStore()

    @MainActor
    @discardableResult
    func resumeRuns(
        awaitingTaskID taskID: UUID,
        taskOutputRows: [[String: WorkspaceAppStorageValue]] = [],
        consumedTokens: Int = 0,
        workspace: Workspace,
        modelContext: ModelContext
    ) async -> [WorkspaceAppActionExecutionResult] {
        let workspaceID = workspace.id
        let waitingRaw = WorkspaceAppRunStatus.waiting.rawValue
        let waitingRuns = (try? modelContext.fetch(FetchDescriptor<WorkspaceAppRun>(
            predicate: #Predicate {
                $0.statusRaw == waitingRaw
                    && $0.linkedTaskID == taskID
                    && $0.workspaceID == workspaceID
            }
        ))) ?? []

        var results: [WorkspaceAppActionExecutionResult] = []
        for run in waitingRuns {
            guard let app = workspaceApp(id: run.appID, modelContext: modelContext),
                  let manifest = manifest(for: app, workspace: workspace) else {
                continue
            }
            if let result = try? await executor.resume(
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
    func resumeCompletedRuns(modelContext: ModelContext) async -> [WorkspaceAppActionExecutionResult] {
        // Status is stored as `statusRaw`, so SQLite can do this filtering. This
        // used to read every `WorkspaceAppRun` ever recorded and drop all but
        // the waiting ones in memory.
        let waitingRaw = WorkspaceAppRunStatus.waiting.rawValue
        let waitingRuns = (try? modelContext.fetch(FetchDescriptor<WorkspaceAppRun>(
            predicate: #Predicate { $0.statusRaw == waitingRaw }
        ))) ?? []

        var results: [WorkspaceAppActionExecutionResult] = []
        for run in waitingRuns {
            // C1 barrier: a fanned-out run awaits a SET of tasks; a B2 single-task run
            // is the degenerate one-element set (via linkedTaskID). Resume only when
            // EVERY awaited task has completed, re-derived authoritatively from the store.
            let barrier = barrierTaskIDs(for: run)
            guard !barrier.isEmpty else { continue }
            let tasks = barrier.compactMap { agentTask(id: $0, modelContext: modelContext) }

            // Hold the barrier while every awaited task is present and any is still in flight.
            if tasks.count == barrier.count, tasks.contains(where: { !$0.isTerminal }) {
                continue
            }

            let allCompleted = tasks.count == barrier.count && tasks.allSatisfy { $0.status == .completed }
            guard allCompleted else {
                // A task ended terminal-but-not-completed (failed/cancelled/budget) or was
                // removed -> the barrier can never be satisfied. Fail the run instead of
                // stranding it in .waiting forever, surfacing why.
                run.status = .failed
                run.completedAt = Date()
                run.errorMessage = barrierFailureMessage(barrier: barrier, tasks: tasks)
                // Immediate best-effort durable save (matches the prior `try? save()`):
                // the failed status must stick, or the next sweep would re-evaluate this
                // run's barrier forever. The coordinator also refreshes the workspace
                // mirror, which carries run state.
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: workspace(id: run.workspaceID, modelContext: modelContext),
                    modelContext: modelContext
                )
                continue
            }
            guard let workspace = workspace(id: run.workspaceID, modelContext: modelContext),
                  let app = workspaceApp(id: run.appID, modelContext: modelContext),
                  let manifest = manifest(for: app, workspace: workspace) else {
                continue
            }
            let outputRows = tasks.map { taskOutputRow(for: $0) }
            let consumed = tasks.reduce(0) { $0 + consumedTokens(for: $1) }
            if let result = try? await executor.resume(
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

    private func barrierFailureMessage(barrier: [UUID], tasks: [AgentTask]) -> String {
        if tasks.count != barrier.count {
            return "Fan-out failed: an awaited task was removed before completing."
        }
        let failed = tasks.filter { $0.status != .completed }
        return "Fan-out failed: " + failed.map { "\($0.title) (\($0.status.rawValue))" }.joined(separator: ", ")
    }

    private func consumedTokens(for task: AgentTask) -> Int {
        // TOTAL provider spend, not output-only: a high-input/low-output run still burns tokens and
        // must count toward the app's cumulative budget. Use the runtime's `tokensUsed` when set,
        // else `inputTokens + outputTokens`.
        task.runs.reduce(0) { $0 + max($1.tokensUsed, $1.inputTokens + $1.outputTokens) }
    }

    @MainActor
    private func workspace(id: UUID, modelContext: ModelContext) -> Workspace? {
        Self.row(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id }), in: modelContext)
    }

    private func taskOutputRow(for task: AgentTask) -> [String: WorkspaceAppStorageValue] {
        // Slice 10: capture the agent's actual answer (the latest non-empty run output), not just
        // task metadata, so a workflow's outputBinding can bind it forward / persist it. Without
        // this the AI step's result was silently dropped.
        let answer = task.runs
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
            .first(where: { !$0.output.isEmpty })?.output ?? ""
        return [
            "task_id": .text(task.id.uuidString),
            "status": .text(task.status.rawValue),
            "title": .text(task.title),
            "output": .text(answer)
        ]
    }

    @MainActor
    private func agentTask(id: UUID, modelContext: ModelContext) -> AgentTask? {
        Self.row(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }), in: modelContext)
    }

    @MainActor
    private func workspaceApp(id: UUID, modelContext: ModelContext) -> WorkspaceApp? {
        Self.row(FetchDescriptor<WorkspaceApp>(predicate: #Predicate { $0.id == id }), in: modelContext)
    }

    private func manifest(for app: WorkspaceApp, workspace: Workspace) -> WorkspaceAppManifest? {
        try? manifestStore.loadManifest(app: app, workspace: workspace).manifest
    }

    /// The single row a descriptor selects, as a `LIMIT 1` read.
    ///
    /// These lookups resolve one row by primary id and were doing it by fetching
    /// the whole table and scanning the result in memory — once per awaited task
    /// in a fan-out barrier, on a path that runs after every queue pass and on
    /// every workspace open.
    @MainActor
    private static func row<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in modelContext: ModelContext
    ) -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}
