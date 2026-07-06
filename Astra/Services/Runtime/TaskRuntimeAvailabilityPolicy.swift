import Foundation
import ASTRACore
import ASTRAModels

enum TaskRuntimeAvailabilityPolicy {
    /// Runtime readiness controls whether a task can run now; it must not migrate
    /// an existing task to another provider. Provider changes are explicit user actions.
    static func alignAfterReadinessRefresh(
        task: AgentTask,
        runtimeReadinessStates _: [AgentRuntimeID: RuntimeReadinessState],
        cache: RuntimeModelAvailabilityCache,
        now: () -> Date = Date.init
    ) {
        alignModelWithCurrentRuntime(
            task: task,
            cache: cache,
            now: now
        )
    }

    static func alignAfterReadinessRefresh(
        task: AgentTask,
        runtimeReadinessStates _: [AgentRuntimeID: RuntimeReadinessState],
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String,
        now: () -> Date = Date.init
    ) {
        alignModelWithCurrentRuntime(
            task: task,
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            ),
            now: now
        )
    }

    static func alignModelWithCurrentRuntime(
        task: AgentTask,
        cache: RuntimeModelAvailabilityCache,
        now: () -> Date = Date.init
    ) {
        guard task.status != .running else { return }

        let runtime = task.resolvedRuntimeID
        guard AgentRuntimeAdapterRegistry.hasAdapter(for: runtime) else { return }

        let normalized = RuntimeModelAvailability.normalizedModel(
            task.model,
            for: runtime,
            cache: cache
        )
        if task.model != normalized {
            task.model = normalized
            task.updatedAt = now()
        }
    }

    static func alignModelWithCurrentRuntime(
        task: AgentTask,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String,
        now: () -> Date = Date.init
    ) {
        alignModelWithCurrentRuntime(
            task: task,
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            ),
            now: now
        )
    }
}
