import ASTRACore

extension AgentRuntimeProcessLaunchPlan {
    func unsupportedProviderNativeReadOnlyInputBlock(
        for launchResourcePlan: TaskLaunchResourcePlan,
        workspaceCommandsRunInsideManagedExecutor: Bool
    ) -> AgentProcessResult? {
        guard !launchResourcePlan.providerNativeReadOnlyInputPaths.isEmpty,
              runtime == .codexCLI,
              !workspaceCommandsRunInsideManagedExecutor else {
            return nil
        }

        let message = """
        ASTRA blocked this Codex run because the task includes read-only files or folders, but Codex host mode can only add external paths as writable roots. Use a runtime with read-only path projection, run the workspace in ASTRA's managed Docker executor, or remove the read-only input before retrying.
        """
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: "read_only_input_native_access_unavailable",
            runtimeStopMessage: message
        )
    }
}
