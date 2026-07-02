import Foundation
import ASTRACore

extension AgentRuntimeProcessLaunchContext {
    func providerPolicyRender(for runtime: AgentRuntimeID) -> ProviderPolicyRender? {
        if let render = permissionManifest?.providerRender, render.providerID == runtime {
            return render
        }
        if let render = executionPolicy.providerRenderOverride, render.providerID == runtime {
            return render
        }
        return nil
    }

    func requiredProviderPolicyRender(for runtime: AgentRuntimeID) -> ProviderPolicyRender {
        if let render = providerPolicyRender(for: runtime) {
            return render
        }
        return ProviderPolicyRender.failClosedLaunchRender(for: runtime)
    }
}

extension ProviderPolicyRender {
    static func failClosedLaunchRender(for runtime: AgentRuntimeID) -> ProviderPolicyRender {
        ProviderPolicyRender(
            providerID: runtime,
            adapterVersion: 0,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: PermissionPolicy.restricted.rawValue,
            allowedTools: [],
            runtimeSupportTools: [],
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: failClosedCLIArguments(for: runtime),
            settingsSummary: "Fail-closed restricted launch render",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [
                PolicyDiagnostic(
                    id: "provider-render.missing-launch-render",
                    severity: .warning,
                    title: "Provider render missing at launch",
                    message: "ASTRA fell back to a restricted ProviderPolicyRender because no persisted provider render was available at launch assembly.",
                    affectedCapability: "provider_policy",
                    remediation: "Record and pass a RunPermissionManifest before launching provider processes."
                )
            ],
            usesBroadProviderPermissions: false
        )
    }

    private static func failClosedCLIArguments(for runtime: AgentRuntimeID) -> [String] {
        switch runtime {
        case .antigravityCLI:
            return antigravityLaunchPermissionArguments(policy: .restricted)
        case .codexCLI:
            return codexLaunchPermissionArguments(policy: .restricted, resumingNativeSession: false)
        case .cursorCLI:
            return cursorLaunchPermissionArguments(policy: .restricted)
        case .openCodeCLI:
            return openCodeLaunchPermissionArguments(policy: .restricted)
        case .claudeCode, .copilotCLI:
            return []
        default:
            return []
        }
    }

    var launchPermissionPolicy: PermissionPolicy {
        PermissionPolicy(rawValue: permissionMode) ?? .restricted
    }

    func claudeLaunchPermissionArguments() -> [String] {
        launchPermissionPolicy.cliArguments
    }

    static func claudeLaunchPermissionArguments(policy: PermissionPolicy) -> [String] {
        policy.cliArguments
    }

    func codexLaunchPermissionArguments(resumingNativeSession: Bool) -> [String] {
        if resumingNativeSession {
            return CodexCLIRuntime.codexResumePermissionArguments(policy: launchPermissionPolicy)
        }
        return cliArgumentsSummary
    }

    static func codexLaunchPermissionArguments(
        policy: PermissionPolicy,
        resumingNativeSession: Bool
    ) -> [String] {
        if resumingNativeSession {
            return CodexCLIRuntime.codexResumePermissionArguments(policy: policy)
        }
        return CodexCLIRuntime.codexPermissionArguments(policy: policy)
    }

    func cursorLaunchPermissionArguments() -> [String] {
        cliArgumentsSummary
    }

    static func cursorLaunchPermissionArguments(policy: PermissionPolicy) -> [String] {
        CursorCLIRuntime.cursorPermissionArguments(policy: policy)
    }

    func antigravityLaunchPermissionArguments() -> [String] {
        cliArgumentsSummary
    }

    static func antigravityLaunchPermissionArguments(policy: PermissionPolicy) -> [String] {
        AntigravityCLIRuntime.antigravityPermissionArguments(policy: policy)
    }

    func openCodeLaunchPermissionArguments() -> [String] {
        cliArgumentsSummary
    }

    static func openCodeLaunchPermissionArguments(policy: PermissionPolicy) -> [String] {
        OpenCodeCLIRuntime.permissionArguments(policy: policy)
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

    static func copilotLaunchPermissionArguments(
        policy: PermissionPolicy,
        allowedTools: [String],
        capabilities: CopilotCLICapabilities,
        localToolCommands: [String],
        runtimeSupportTools: [String],
        allowAllPathsForSSHConnections: Bool
    ) -> [String] {
        var args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: policy,
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
           policy != .autonomous,
           capabilities.supportsAllowAllPaths,
           !args.contains("--allow-all-paths") {
            args.append("--allow-all-paths")
        }
        return args
    }

    static func copilotUtilityLaunchPermissionArguments(
        allowedTools: [String],
        capabilities: CopilotCLICapabilities
    ) -> [String] {
        copilotLaunchPermissionArguments(
            policy: .restricted,
            allowedTools: allowedTools,
            capabilities: capabilities,
            localToolCommands: [],
            runtimeSupportTools: [],
            allowAllPathsForSSHConnections: false
        )
    }
}
