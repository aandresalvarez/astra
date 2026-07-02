import Foundation
import ASTRACore

struct AgentRuntimeExecutionPolicy: Equatable {
    var permissionPolicyOverride: PermissionPolicy?
    var allowedToolsOverride: [String]?
    var permissionGrantsOverride: [PermissionGrant]?
    var providerRenderOverride: ProviderPolicyRender?

    static let `default` = AgentRuntimeExecutionPolicy()

    init(
        permissionPolicyOverride: PermissionPolicy? = nil,
        allowedToolsOverride: [String]? = nil,
        permissionGrantsOverride: [PermissionGrant]? = nil,
        providerRenderOverride: ProviderPolicyRender? = nil
    ) {
        self.permissionPolicyOverride = permissionPolicyOverride
        self.allowedToolsOverride = allowedToolsOverride
        self.permissionGrantsOverride = permissionGrantsOverride
        self.providerRenderOverride = providerRenderOverride
    }

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
            permissionGrantsOverride: permissionGrantsOverride,
            providerRenderOverride: render
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
            permissionGrantsOverride: nil,
            providerRenderOverride: nil
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
            permissionGrantsOverride: grants,
            providerRenderOverride: nil
        )
    }
}
