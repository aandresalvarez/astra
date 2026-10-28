import ASTRAModels

@MainActor
struct AgentRuntimeExecutionContext {
    private let projection: DetachedLaunchProjection
    var task: AgentTask { projection.task }
    let executionPath: String
    let shouldCleanupIsolation: Bool

    static func make(
        launchTask: AgentTask,
        executionPath: String,
        shouldCleanupIsolation: Bool
    ) -> AgentRuntimeExecutionContext {
        let projection = DetachedLaunchProjection(
            AgentTaskLaunchSnapshot(task: launchTask),
            from: launchTask
        )
        projection.task.executionRootPath = executionPath
        return AgentRuntimeExecutionContext(
            projection: projection,
            executionPath: executionPath,
            shouldCleanupIsolation: shouldCleanupIsolation && TaskWorktreeBinding.payload(for: launchTask) == nil
        )
    }

    func cleanup() {
        guard shouldCleanupIsolation else { return }
        IsolationService.cleanup(task: task, executionPath: executionPath)
    }
}
