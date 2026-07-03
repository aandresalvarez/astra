import Foundation
import ASTRACore

enum ProviderPolicyModeResolver {
    static func mode(
        for policy: AgentPolicy,
        runtime: AgentRuntimeID,
        executionEnvironment: WorkspaceExecutionEnvironment? = nil
    ) -> ProviderPermissionMode {
        applyingRuntimeExecutionClamp(
            baseMode(for: policy),
            runtime: runtime,
            executionEnvironment: executionEnvironment
        )
    }

    /// Runtime/execution-environment clamp applied on top of the policy-derived
    /// mode. Copilot in a Docker workspace bypasses its own confinement, so an
    /// `.autonomous` mode is forced down to `.restricted` — ASTRA's wrap is the
    /// only remaining boundary there. This is the single implementation of that
    /// rule; `AgentRuntimeProviderLaunchPolicy` delegates here so the two paths
    /// (policy render vs. launch-time clamp) cannot drift.
    static func applyingRuntimeExecutionClamp(
        _ mode: ProviderPermissionMode,
        runtime: AgentRuntimeID,
        executionEnvironment: WorkspaceExecutionEnvironment?
    ) -> ProviderPermissionMode {
        if runtime == .copilotCLI,
           let executionEnvironment,
           DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment),
           mode == .autonomous {
            return .restricted
        }
        return mode
    }

    static func permissionPolicy(
        for policy: AgentPolicy,
        runtime: AgentRuntimeID,
        executionEnvironment: WorkspaceExecutionEnvironment? = nil
    ) -> PermissionPolicy {
        PermissionPolicy(providerMode: mode(
            for: policy,
            runtime: runtime,
            executionEnvironment: executionEnvironment
        ))
    }

    private static func baseMode(for policy: AgentPolicy) -> ProviderPermissionMode {
        switch policy.level {
        case .autonomous:
            return .autonomous
        case .locked:
            return .restricted
        case .review, .build, .network:
            return .restricted
        case .custom:
            return customPolicyResolvesToRestricted(policy) ? .restricted : .interactive
        }
    }

    /// Whether a `.custom` policy must resolve to `.restricted` (so providers
    /// still receive the generated read-only allow/deny permissions) rather than
    /// falling back to `.interactive`.
    ///
    /// A custom policy stays restricted when it either (a) permits a mutating
    /// tool or shell pattern — it needs the write-sandbox / allow-list backstop —
    /// or (b) explicitly denies mutation. Case (b) covers the read-only/locked
    /// preset after `AgentPolicyDefaults` has relabeled it to `.custom`: the
    /// locked preset expresses read-only intent as *denied* tools/shell, so
    /// without this a persisted read-only default would fall through to
    /// `.interactive` and silently drop the allow/deny that enforced the preset
    /// (e.g. Claude would stop generating its read-only permission set). This
    /// mirrors the explicit `.locked` branch above, which already resolves to
    /// `.restricted`.
    private static func customPolicyResolvesToRestricted(_ policy: AgentPolicy) -> Bool {
        let mutatingTools = Set(["bash", "edit", "multiedit", "write", "notebookedit"])
        let allowedTools = policy.allowedTools.map(normalizedToolName)
        if allowedTools.contains(where: mutatingTools.contains) {
            return true
        }
        if !policy.allowedShellPatterns.isEmpty || !policy.askFirstShellPatterns.isEmpty {
            return true
        }
        // Read-only intent expressed as denies (the relabeled locked preset).
        let deniedTools = policy.deniedTools.map(normalizedToolName)
        if deniedTools.contains(where: mutatingTools.contains) {
            return true
        }
        return !policy.deniedShellPatterns.isEmpty
    }

    private static func normalizedToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parenIndex = trimmed.firstIndex(of: "(") else { return trimmed }
        return String(trimmed[..<parenIndex])
    }
}
