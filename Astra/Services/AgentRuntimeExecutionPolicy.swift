import Foundation
import ASTRACore

struct AgentRuntimeExecutionPolicy: Equatable {
    var permissionPolicyOverride: PermissionPolicy?
    var allowedToolsOverride: [String]?

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
            allowedToolsOverride: render.allowedTools
        )
    }

    static func approvedPlan(
        runtime: AgentRuntimeID,
        currentPermissionPolicy: PermissionPolicy,
        allowedTools: [String]
    ) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: runtime.permissionPolicyAfterUserApprovedPlan(
                current: currentPermissionPolicy
            ),
            allowedToolsOverride: allowedTools
        )
    }

    static func approvedRuntimePermission(runtime: AgentRuntimeID, allowedTools: [String]) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: runtime.permissionPolicyAfterUserApprovedRuntimePermission(),
            allowedToolsOverride: allowedTools
        )
    }
}

private extension AgentRuntimeID {
    func permissionPolicyAfterUserApprovedPlan(current: PermissionPolicy) -> PermissionPolicy {
        switch self {
        case .claudeCode:
            return current
        case .copilotCLI:
            return current
        }
    }

    func permissionPolicyAfterUserApprovedRuntimePermission() -> PermissionPolicy {
        switch self {
        case .claudeCode, .copilotCLI:
            return .restricted
        }
    }
}
