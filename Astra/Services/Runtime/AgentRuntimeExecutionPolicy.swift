import Foundation
import ASTRACore

struct AgentRuntimeExecutionPolicy: Equatable {
    var permissionPolicyOverride: PermissionPolicy?
    var allowedToolsOverride: [String]?
    var permissionGrantsOverride: [PermissionGrant]?
    var providerRenderOverride: ProviderPolicyRender?
    /// External-operation observations must be evaluated by a fresh provider
    /// process. The Context Capsule remains authoritative, so native provider
    /// continuation is an optimization that callers may explicitly disable.
    var allowsNativeContinuation: Bool

    static let `default` = AgentRuntimeExecutionPolicy()

    init(
        permissionPolicyOverride: PermissionPolicy? = nil,
        allowedToolsOverride: [String]? = nil,
        permissionGrantsOverride: [PermissionGrant]? = nil,
        providerRenderOverride: ProviderPolicyRender? = nil,
        allowsNativeContinuation: Bool = true
    ) {
        self.permissionPolicyOverride = permissionPolicyOverride
        self.allowedToolsOverride = allowedToolsOverride
        self.permissionGrantsOverride = permissionGrantsOverride
        self.providerRenderOverride = providerRenderOverride
        self.allowsNativeContinuation = allowsNativeContinuation
    }

    func permissionPolicy(default defaultPolicy: PermissionPolicy) -> PermissionPolicy {
        permissionPolicyOverride ?? defaultPolicy
    }

    func allowedTools(default defaultTools: [String]) -> [String] {
        allowedToolsOverride ?? defaultTools
    }

    func applyingProviderRender(_ render: ProviderPolicyRender) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: PermissionPolicy(providerMode: render.permissionMode),
            allowedToolsOverride: render.allowedTools,
            permissionGrantsOverride: permissionGrantsOverride,
            providerRenderOverride: render,
            allowsNativeContinuation: allowsNativeContinuation
        )
    }

    static let externalOperationWake = AgentRuntimeExecutionPolicy(
        allowsNativeContinuation: false
    )

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

enum AgentRuntimeProviderLaunchPolicy {
    static func mode(
        runtime: AgentRuntimeID,
        effectiveProviderMode: ProviderPermissionMode,
        executionEnvironment: WorkspaceExecutionEnvironment
    ) -> ProviderPermissionMode {
        // Single source of truth for the Copilot+Docker autonomous→restricted
        // clamp lives in ProviderPolicyModeResolver so the launch-time path and
        // the policy-render path cannot diverge.
        ProviderPolicyModeResolver.applyingRuntimeExecutionClamp(
            effectiveProviderMode,
            runtime: runtime,
            executionEnvironment: executionEnvironment
        )
    }

    static func permissionPolicy(
        runtime: AgentRuntimeID,
        effectivePermissionPolicy: PermissionPolicy,
        executionEnvironment: WorkspaceExecutionEnvironment
    ) -> PermissionPolicy {
        PermissionPolicy(providerMode: mode(
            runtime: runtime,
            effectiveProviderMode: effectivePermissionPolicy.providerPermissionMode,
            executionEnvironment: executionEnvironment
        ))
    }
}
