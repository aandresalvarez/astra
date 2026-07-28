import Foundation
import ASTRACore
import ASTRAModels

struct AgentRuntimeExecutionPolicy: Equatable {
    var permissionPolicyOverride: PermissionPolicy?
    var allowedToolsOverride: [String]?
    var permissionGrantsOverride: [PermissionGrant]?
    var providerRenderOverride: ProviderPolicyRender?
    /// Immutable request-time configuration. This is intentionally process
    /// local: it is supplied by the durable request snapshot and is never
    /// written back to the editable AgentTask model.
    var launchSnapshot: AgentTaskLaunchSnapshot?
    /// The workspace access actually admitted by the queue. This process-local
    /// value keeps runtime mounts and grants aligned with the acquired lease
    /// when an explicitly disabled sandbox upgrades a legacy shared claim to
    /// exclusive serialization.
    var workspaceAccessOverride: TaskExecutionResourceAccess?
    /// The persisted sandbox setting observed when the queue began resource
    /// admission. A run must use the same value at launch so a concurrent
    /// settings toggle cannot leave a shared lease without its read-only
    /// boundary or turn an Off admission into hidden confinement.
    var sandboxEnforcementSnapshot: ExecutionSandboxEnforcement?

    static let `default` = AgentRuntimeExecutionPolicy()

    init(
        permissionPolicyOverride: PermissionPolicy? = nil,
        allowedToolsOverride: [String]? = nil,
        permissionGrantsOverride: [PermissionGrant]? = nil,
        providerRenderOverride: ProviderPolicyRender? = nil,
        launchSnapshot: AgentTaskLaunchSnapshot? = nil,
        workspaceAccessOverride: TaskExecutionResourceAccess? = nil,
        sandboxEnforcementSnapshot: ExecutionSandboxEnforcement? = nil
    ) {
        self.permissionPolicyOverride = permissionPolicyOverride
        self.allowedToolsOverride = allowedToolsOverride
        self.permissionGrantsOverride = permissionGrantsOverride
        self.providerRenderOverride = providerRenderOverride
        self.launchSnapshot = launchSnapshot
        self.workspaceAccessOverride = workspaceAccessOverride
        self.sandboxEnforcementSnapshot = sandboxEnforcementSnapshot
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
            launchSnapshot: launchSnapshot,
            workspaceAccessOverride: workspaceAccessOverride,
            sandboxEnforcementSnapshot: sandboxEnforcementSnapshot
        )
    }

    func withLaunchSnapshot(_ snapshot: AgentTaskLaunchSnapshot?) -> AgentRuntimeExecutionPolicy {
        var copy = self
        copy.launchSnapshot = snapshot
        return copy
    }

    func withResourceAdmission(
        workspaceAccess: TaskExecutionResourceAccess?,
        sandboxEnforcement: ExecutionSandboxEnforcement?
    ) -> AgentRuntimeExecutionPolicy {
        var copy = self
        copy.workspaceAccessOverride = workspaceAccess
        copy.sandboxEnforcementSnapshot = sandboxEnforcement
        return copy
    }

    func withResourceAdmission(
        from source: AgentRuntimeExecutionPolicy
    ) -> AgentRuntimeExecutionPolicy {
        withResourceAdmission(
            workspaceAccess: source.workspaceAccessOverride,
            sandboxEnforcement: source.sandboxEnforcementSnapshot
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
