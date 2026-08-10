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
    /// Immutable current-turn intent captured by the durable request.
    var turnIntentSnapshot: TaskTurnIntentSnapshot?
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
        turnIntentSnapshot: TaskTurnIntentSnapshot? = nil,
        workspaceAccessOverride: TaskExecutionResourceAccess? = nil,
        sandboxEnforcementSnapshot: ExecutionSandboxEnforcement? = nil
    ) {
        self.permissionPolicyOverride = permissionPolicyOverride
        self.allowedToolsOverride = allowedToolsOverride
        self.permissionGrantsOverride = permissionGrantsOverride
        self.providerRenderOverride = providerRenderOverride
        self.launchSnapshot = launchSnapshot
        self.turnIntentSnapshot = turnIntentSnapshot
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
            turnIntentSnapshot: turnIntentSnapshot,
            workspaceAccessOverride: workspaceAccessOverride,
            sandboxEnforcementSnapshot: sandboxEnforcementSnapshot
        )
    }

    func withLaunchSnapshot(_ snapshot: AgentTaskLaunchSnapshot?) -> AgentRuntimeExecutionPolicy {
        var copy = self
        copy.launchSnapshot = snapshot
        return copy
    }

    func withTurnIntentSnapshot(_ snapshot: TaskTurnIntentSnapshot?) -> AgentRuntimeExecutionPolicy {
        var copy = self
        copy.turnIntentSnapshot = snapshot
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

    /// A one-run approval is *additive authority* and carries no permission
    /// policy of its own.
    ///
    /// This used to hardcode `.restricted`, reasoning that granting specific
    /// tools must never relax the enforcement tier. It doesn't relax anything —
    /// but it did silently *tighten* it, and that is what broke: approving one
    /// credential prompt on an Auto-mode task set a non-autonomous override,
    /// which `TaskPolicyStore.resolve` then read as a cap and downgraded the run
    /// to `review`, which re-enabled the brokered enforcement tier the user had
    /// deliberately switched off. The user said yes to one thing and lost Auto
    /// for the whole run.
    ///
    /// Leaving the override nil is the honest encoding: the approval adds
    /// `allowedTools` and `grants`, and the run keeps whatever level the task,
    /// workspace, or global default already resolved to. It cannot widen the
    /// baseline (there is no override to widen it with) and it cannot narrow it.
    static func approvedRuntimePermission(
        runtime _: AgentRuntimeID,
        allowedTools: [String],
        grants: [PermissionGrant] = []
    ) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: nil,
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
