import Foundation
import ASTRACore

enum TaskRuntimeAvailabilityPolicy {
    /// Runtime readiness controls whether a task can run now; it must not migrate
    /// an existing task to another provider. Provider changes are explicit user actions.
    static func alignAfterReadinessRefresh(
        task: AgentTask,
        runtimeReadinessStates _: [AgentRuntimeID: RuntimeReadinessState],
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String,
        now: () -> Date = Date.init
    ) {
        alignModelWithCurrentRuntime(
            task: task,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON,
            now: now
        )
    }

    static func alignModelWithCurrentRuntime(
        task: AgentTask,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String,
        now: () -> Date = Date.init
    ) {
        guard task.status != .running else { return }

        let runtime = task.resolvedRuntimeID
        let normalized = RuntimeModelAvailability.normalizedModel(
            task.model,
            for: runtime,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON
        )
        if task.model != normalized {
            task.model = normalized
            task.updatedAt = now()
        }
    }
}
