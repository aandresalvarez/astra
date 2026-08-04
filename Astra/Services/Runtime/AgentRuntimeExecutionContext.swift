import ASTRAModels

@MainActor
struct AgentRuntimeExecutionContext {
    let task: AgentTask
    let executionPath: String
    let shouldCleanupIsolation: Bool

    static func make(
        launchTask: AgentTask,
        executionPath: String,
        shouldCleanupIsolation: Bool
    ) -> AgentRuntimeExecutionContext {
        let executionTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(
            AgentTaskLaunchSnapshot(task: launchTask),
            from: launchTask
        )
        executionTask.executionRootPath = executionPath
        return AgentRuntimeExecutionContext(
            task: executionTask,
            executionPath: executionPath,
            shouldCleanupIsolation: shouldCleanupIsolation
        )
    }

    func cleanup() {
        guard shouldCleanupIsolation else { return }
        IsolationService.cleanup(task: task, executionPath: executionPath)
    }
}
