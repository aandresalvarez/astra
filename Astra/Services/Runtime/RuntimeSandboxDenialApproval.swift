import Foundation
import ASTRACore

enum RuntimeSandboxDenialApproval {
    enum Decision {
        case request(PermissionRequest, [PermissionGrant])
        case terminal(reason: String, message: String)
    }

    static func resolve(
        denial: RuntimeSandboxFileDenial,
        toolName: String,
        requestText: String
    ) -> Decision {
        let pathDecision = RuntimeSandboxPathGrantPolicy.evaluate(
            path: denial.path,
            operation: denial.operation
        )
        guard case .eligible(let path, let access) = pathDecision else {
            let reason: String
            if case .denied(let value) = pathDecision {
                reason = value
            } else {
                reason = "sandbox_path_not_approvable"
            }
            return .terminal(
                reason: denial.stopReason,
                message: "ASTRA's macOS sandbox denied \(toolName) \(denial.operation.rawValue) access to \(denial.path). This path cannot be approved interactively because it is outside ASTRA's bounded read-approval policy (\(reason)).\(requestText) Detail: \(denial.detail)"
            )
        }
        let request = PermissionRequest.sandboxPath(path: path, access: access, toolName: toolName)
        let grants = PermissionBroker.approvalGrants(for: request)
        guard !grants.isEmpty else {
            return .terminal(
                reason: "os_sandbox_permission_unresumable",
                message: "ASTRA could not create a bounded one-run sandbox grant for \(path)."
            )
        }
        return .request(request, grants)
    }
}
