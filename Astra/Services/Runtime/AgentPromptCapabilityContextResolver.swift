import ASTRACore
import ASTRAModels

struct AgentPromptCapabilityContext {
    let runtime: AgentRuntimeID
    let snapshot: TaskCapabilityResolutionSnapshot
}

enum AgentPromptCapabilityContextResolver {
    @MainActor
    static func followUp(
        task: AgentTask,
        message: String,
        executionPolicy: AgentRuntimeExecutionPolicy
    ) -> AgentPromptCapabilityContext {
        let intent = executionPolicy.turnIntentSnapshot
            ?? TaskTurnIntentResolver.capture(
                for: task,
                sourceEventID: nil,
                acceptedTurn: message,
                includeTaskInputs: false
            )
        let runtime = executionPolicy.launchSnapshot?.runtimeID
            .flatMap(AgentRuntimeID.init(rawValue:))
            ?? task.resolvedRuntimeID
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: message,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? [],
            turnIntentSnapshot: intent,
            runtime: runtime
        )
        return AgentPromptCapabilityContext(runtime: runtime, snapshot: snapshot)
    }
}
