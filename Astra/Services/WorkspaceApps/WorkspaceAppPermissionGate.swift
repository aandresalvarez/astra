import Foundation
import ASTRAModels

protocol WorkspaceAppPermissionChecking {
    func enforce(
        action: WorkspaceAppActionSpec,
        mode: WorkspaceAppPermissionMode,
        input: WorkspaceAppActionInput,
        surface: WorkspaceAppBridgeSurface
    ) throws
}

struct WorkspaceAppPermissionGate: WorkspaceAppPermissionChecking {
    func enforce(
        action: WorkspaceAppActionSpec,
        mode: WorkspaceAppPermissionMode,
        input: WorkspaceAppActionInput,
        surface: WorkspaceAppBridgeSurface
    ) throws {
        switch WorkspaceAppActionEffect.effect(for: action.type) {
        case .read:
            return
        case .localWrite:
            guard mode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform local write action '\(action.id)'."
                )
            }
        case .externalWrite:
            switch mode {
            case .preApproved:
                return
            case .approvalRequired:
                guard input.confirmedApproval else {
                    throw WorkspaceAppActionExecutionError.permissionDenied(
                        "External write action '\(action.id)' requires explicit approval before execution."
                    )
                }
            case .draftOnly:
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Draft-only workspace apps cannot submit external write action '\(action.id)'."
                )
            case .readOnly:
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot submit external write action '\(action.id)'."
                )
            }
        case .destructive:
            guard mode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform destructive action '\(action.id)'."
                )
            }
            guard input.confirmedDestructive else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Destructive action '\(action.id)' requires explicit confirmation before execution."
                )
            }
        }
    }
}
