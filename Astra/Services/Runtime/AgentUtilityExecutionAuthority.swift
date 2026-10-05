import Foundation

extension AgentUtilityRuntimeRunner {
    static func runBoundPrompt(_ prompt: String, executionContext: TaskExecutionContext,
        configuration: AgentUtilityRuntimeConfiguration, toolMode: AgentUtilityToolMode = .none) async -> AgentUtilityRunResult {
        guard executionContext.isValid, executionContext.resourceScope == nil else {
            let reason = "scoped_utility_not_supported"
            AppLogger.warning("Utility validation was blocked: \(reason). The provider cannot enforce inherited resource authority.",
                category: "Validation")
            return .init(exitCode: -1, output: "",
                error: "\(reason): use deterministic validation or supplied evidence; a restricted tool list is not filesystem read confinement.")
        }
        return await runPrompt(prompt, workspacePath: executionContext.workingDirectory,
            configuration: configuration, toolMode: toolMode)
    }
}
