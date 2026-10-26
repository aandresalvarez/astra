import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension WorkspaceConfigManager {
    static func prepareCodexUsageHistoryImport(_ config: TaskConfig, task: AgentTask,
                                               runs: [TaskRun], context: ModelContext) {
        guard runs.contains(where: { $0.runtimeID == AgentRuntimeID.codexCLI.rawValue && $0.providerSessionId != nil }) else { return }
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.completedCodexSessionUsageCorrectionBuild)
        guard config.codexUsageHistoryComplete != true,
              !task.events.contains(where: { $0.type == CodexUsageHistory.incompleteEventType }) else { return }
        context.insert(TaskEvent(task: task, type: CodexUsageHistory.incompleteEventType,
            payload: "Historical Codex usage was preserved because this import does not establish a complete accounting history."))
    }

    /// Completeness is derived from what this mirror actually retains. A later
    /// export must never turn a previously truncated import into a full history.
    static func completeCodexUsageHistory(task: AgentTask, runs: [TaskRun], events: [EventConfig]) -> Bool? {
        let codex = task.runs.filter { $0.runtimeID == AgentRuntimeID.codexCLI.rawValue && $0.providerSessionId != nil }
        guard !codex.isEmpty else { return nil }
        guard !task.events.contains(where: { $0.type == CodexUsageHistory.incompleteEventType }) else { return false }
        let ids = Set(codex.map(\.id))
        guard ids.count == codex.count, ids.isSubset(of: Set(runs.map(\.id))) else { return false }
        let evidence = task.events.filter { !$0.isDeleted && $0.run.map { ids.contains($0.id) } == true
            && ($0.type == "task.stats" || $0.type.hasPrefix("astra.provider_session_usage_")) }
        let exported = Dictionary(events.compactMap { event in event.id.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first })
        return evidence.allSatisfy { event in
            guard let mirror = exported[event.id.uuidString] else { return false }
            return mirror.payload == event.payload && mirror.runIndex != nil
        }
    }
}
