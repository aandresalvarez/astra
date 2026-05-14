import Foundation
import SwiftData

@MainActor
enum AgentRuntimeRunPersistence {
    static func recordSessionTurn(
        task: AgentTask,
        run: TaskRun,
        message: String
    ) {
        let folder = (try? task.ensureTaskFolder()) ?? ""
        guard !folder.isEmpty else { return }

        SessionHistoryManager.recordTurn(
            taskFolder: folder,
            taskTitle: task.title,
            turnMessage: message,
            output: run.output,
            tokensUsed: run.tokensUsed,
            costUSD: run.costUSD,
            fileChanges: run.fileChanges,
            redactions: AgentSensitiveRedactions.values(for: task),
            durationMs: run.completedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) }
        )
    }

    static func finalizeAndPersist(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String
    ) {
        AgentEventCompactor.compactEvents(for: task, modelContext: modelContext)
        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: modelContext)

        let finishedAt = Date()
        task.updatedAt = finishedAt
        if task.isTerminal {
            task.completedAt = finishedAt
        }
        task.markUnreadForCurrentStatus(at: finishedAt)

        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: fields(task: task, run: run, phase: phase)
        )
    }

    static func fields(task: AgentTask, run: TaskRun, phase: String) -> [String: String] {
        let runEvents = task.events.filter { $0.run?.id == run.id }
        return [
            "phase": phase,
            "runtime": run.runtimeID ?? task.resolvedRuntimeID.rawValue,
            "task_status": task.status.rawValue,
            "run_status": run.status.rawValue,
            "run_stop_reason": run.stopReason,
            "exit_code": run.exitCode.map(String.init) ?? "none",
            "run_output_chars": String(run.output.count),
            "response_event_count": String(runEvents.filter { $0.type == "agent.response" }.count),
            "thinking_event_count": String(runEvents.filter { $0.type == "agent.thinking" }.count),
            "tool_use_event_count": String(runEvents.filter { $0.type == "tool.use" }.count),
            "tool_result_event_count": String(runEvents.filter { $0.type == "tool.result" }.count),
            "error_event_count": String(runEvents.filter { $0.type == "error" }.count),
            "run_event_count": String(runEvents.count),
            "file_changes": String(run.fileChanges.count),
            "tokens_input": String(run.inputTokens),
            "tokens_output": String(run.outputTokens),
            "provider_version": run.providerVersion ?? "unknown"
        ]
    }
}
