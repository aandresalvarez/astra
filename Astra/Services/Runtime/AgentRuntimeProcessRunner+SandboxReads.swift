import Foundation
import ASTRACore
import ASTRAModels

/// Whether a launch of a runtime runs inside an ASTRA sandbox that enforces
/// its read scope. Copilot's home check asks before launch: a startup entry
/// Copilot reads from outside its home is unreachable there, not a warning.
extension AgentRuntimeProcessRunning {
    @MainActor
    func sandboxEnforcesReads(
        runtime _: AgentRuntimeID,
        permissionPolicy _: PermissionPolicy,
        executionPolicy _: AgentRuntimeExecutionPolicy
    ) -> Bool {
        false
    }
}

extension AgentRuntimeProcessRunner {
    /// Resolved from the same settings provider and admission snapshot the
    /// launch itself uses, so the two can never disagree.
    @MainActor
    func sandboxEnforcesReads(
        runtime: AgentRuntimeID,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy
    ) -> Bool {
        let policy = executionPolicy.permissionPolicyOverride ?? permissionPolicy
        let settings = sandboxSettingsProvider(policy)
            .applyingAdmissionSnapshot(executionPolicy.sandboxEnforcementSnapshot, permissionPolicy: policy)
        return settings.enforcement != .off
            && settings.wrappedRuntimes.contains(runtime)
            && settings.readScope == .enforce
    }
}
