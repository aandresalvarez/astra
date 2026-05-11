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

    static func approvedRuntimePermission(runtime: AgentRuntimeID) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: runtime.permissionPolicyAfterUserApprovedRuntimePermission(),
            allowedToolsOverride: nil
        )
    }
}

private extension AgentRuntimeID {
    func permissionPolicyAfterUserApprovedPlan(current: PermissionPolicy) -> PermissionPolicy {
        switch self {
        case .claudeCode:
            return current
        case .copilotCLI:
            switch current {
            case .restricted:
                // Copilot can otherwise stop on a hidden provider approval prompt
                // after ASTRA has already collected explicit user approval.
                return .autonomous
            case .autonomous, .interactive:
                return current
            }
        }
    }

    func permissionPolicyAfterUserApprovedRuntimePermission() -> PermissionPolicy {
        switch self {
        case .claudeCode, .copilotCLI:
            return .autonomous
        }
    }
}
