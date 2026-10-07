import ASTRACore
import ASTRAModels

enum AgentContinuationPrompt {
    @MainActor
    static func build(
        message: String,
        task: AgentTask,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionPolicy: PermissionPolicy,
        contextText: String,
        repositoryStatus: HealthStatus?,
        runEnvironment: AgentRuntimeRunEnvironmentContext
    ) -> String {
        let base = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: message, task: task, executionPolicy: executionPolicy,
            usesNativeContinuation: true
        )
        let policy = HostControlPlanePromptGuidance.appendingAutoSendGuidance(
            to: AskGitPullRequestWorkflowPolicy.appendingProviderGuidance(
                to: base, task: task, permissionPolicy: permissionPolicy, contextText: contextText
            ),
            permissionPolicy: permissionPolicy
        )
        return runEnvironment.appendingReadOnlyInputGuidance(to:
            GitHubCapabilityLaunchContext.appendingProviderGuidance(to: policy, repositoryStatus: repositoryStatus))
    }
}
