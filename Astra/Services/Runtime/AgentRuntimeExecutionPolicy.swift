import Foundation
import ASTRACore

struct AgentRuntimeExecutionPolicy: Equatable {
    var permissionPolicyOverride: PermissionPolicy?
    var allowedToolsOverride: [String]?
    var permissionGrantsOverride: [PermissionGrant]?

    static let `default` = AgentRuntimeExecutionPolicy()

    func permissionPolicy(default defaultPolicy: PermissionPolicy) -> PermissionPolicy {
        permissionPolicyOverride ?? defaultPolicy
    }

    func allowedTools(default defaultTools: [String]) -> [String] {
        allowedToolsOverride ?? defaultTools
    }

    func applyingProviderRender(_ render: ProviderPolicyRender) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: PermissionPolicy(rawValue: render.permissionMode) ?? permissionPolicyOverride,
            allowedToolsOverride: render.allowedTools,
            permissionGrantsOverride: permissionGrantsOverride
        )
    }

    static func approvedPlan(
        runtime _: AgentRuntimeID,
        currentPermissionPolicy: PermissionPolicy,
        allowedTools: [String]
    ) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: currentPermissionPolicy,
            allowedToolsOverride: allowedTools,
            permissionGrantsOverride: nil
        )
    }

    /// A one-run approval is always `.restricted`: granting specific tools for a
    /// single run must never relax the OS-level enforcement tier. The policy is
    /// intentionally hardcoded (not a parameter) so a caller cannot accidentally
    /// widen a per-run approval to `.autonomous`.
    static func approvedRuntimePermission(
        runtime _: AgentRuntimeID,
        allowedTools: [String],
        grants: [PermissionGrant] = []
    ) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: .restricted,
            allowedToolsOverride: allowedTools,
            permissionGrantsOverride: grants
        )
    }
}
