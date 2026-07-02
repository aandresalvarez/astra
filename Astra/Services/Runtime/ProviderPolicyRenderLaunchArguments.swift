import Foundation
import ASTRACore

extension AgentRuntimeProcessLaunchContext {
    func providerPolicyRender(for runtime: AgentRuntimeID) -> ProviderPolicyRender? {
        if let render = executionPolicy.providerRenderOverride, render.providerID == runtime {
            return render
        }
        if let render = permissionManifest?.providerRender, render.providerID == runtime {
            return render
        }
        return nil
    }
}

extension ProviderPolicyRender {
    var launchPermissionPolicy: PermissionPolicy {
        PermissionPolicy(rawValue: permissionMode) ?? .restricted
    }

    func claudeLaunchPermissionArguments() -> [String] {
        launchPermissionPolicy.cliArguments
    }

    func codexLaunchPermissionArguments(resumingNativeSession: Bool) -> [String] {
        if resumingNativeSession {
            return CodexCLIRuntime.codexResumePermissionArguments(policy: launchPermissionPolicy)
        }
        return cliArgumentsSummary
    }

    func cursorLaunchPermissionArguments() -> [String] {
        cliArgumentsSummary
    }

    func antigravityLaunchPermissionArguments() -> [String] {
        cliArgumentsSummary
    }

    func openCodeLaunchPermissionArguments() -> [String] {
        cliArgumentsSummary
    }

    func copilotLaunchPermissionArguments(
        capabilities: CopilotCLICapabilities,
        localToolCommands: [String],
        runtimeSupportTools: [String],
        allowAllPathsForSSHConnections: Bool
    ) -> [String] {
        var args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: launchPermissionPolicy,
            allowedTools: allowedTools,
            localToolCommands: localToolCommands,
            runtimeSupportTools: runtimeSupportTools,
            supportsAllowAll: capabilities.supportsAllowAll,
            supportsAllowAllTools: capabilities.supportsAllowAllTools,
            supportsAllowAllPaths: capabilities.supportsAllowAllPaths,
            supportsAllowAllURLs: capabilities.supportsAllowAllURLs,
            requiresAllowAllToolsForPrompt: capabilities.requiresAllowAllToolsForPrompt
        )
        if allowAllPathsForSSHConnections,
           launchPermissionPolicy != .autonomous,
           capabilities.supportsAllowAllPaths,
           !args.contains("--allow-all-paths") {
            args.append("--allow-all-paths")
        }
        return args
    }
}
