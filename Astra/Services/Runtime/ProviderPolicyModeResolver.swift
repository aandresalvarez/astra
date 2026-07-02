import Foundation
import ASTRACore

enum ProviderPolicyModeResolver {
    static func mode(
        for policy: AgentPolicy,
        runtime: AgentRuntimeID,
        executionEnvironment: WorkspaceExecutionEnvironment? = nil
    ) -> ProviderPermissionMode {
        var mode = baseMode(for: policy)
        if runtime == .copilotCLI,
           let executionEnvironment,
           DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment),
           mode == .autonomous {
            mode = .restricted
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
            return customPolicyNeedsWriteSandbox(policy) ? .restricted : .interactive
        }
    }

    private static func customPolicyNeedsWriteSandbox(_ policy: AgentPolicy) -> Bool {
        let mutatingTools = Set(["bash", "edit", "multiedit", "write", "notebookedit"])
        let allowedTools = policy.allowedTools.map(normalizedToolName)
        if allowedTools.contains(where: mutatingTools.contains) {
            return true
        }
        return !policy.allowedShellPatterns.isEmpty || !policy.askFirstShellPatterns.isEmpty
    }

    private static func normalizedToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parenIndex = trimmed.firstIndex(of: "(") else { return trimmed }
        return String(trimmed[..<parenIndex])
    }
}
