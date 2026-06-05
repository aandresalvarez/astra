import Foundation

struct TaskRunStopReason: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    let rawValue: String

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static func custom(_ rawValue: String) -> TaskRunStopReason? {
        TaskRunStopReason(rawValue: rawValue)
    }

    static let appRestarted: TaskRunStopReason = "app_restarted"
    static let browserActionBudgetExceeded: TaskRunStopReason = "browser_action_budget_exceeded"
    static let cancelled: TaskRunStopReason = "cancelled"
    static let capabilityRuntimeResourcesMissing: TaskRunStopReason = "capability_runtime_resources_missing"
    static let completed: TaskRunStopReason = "completed"
    static let connectorPreflightFailed: TaskRunStopReason = "connector_preflight_failed"
    static let deliverableVerificationFailed: TaskRunStopReason = "deliverable_verification_failed"
    static let failed: TaskRunStopReason = "failed"
    static let inferredValidationFailed: TaskRunStopReason = "inferred_validation_failed"
    static let isolationFailed: TaskRunStopReason = "isolation_failed"
    static let maxBudgetReached: TaskRunStopReason = "max_budget_reached"
    static let maxTurnsReached: TaskRunStopReason = "max_turns_reached"
    static let noUsableResult: TaskRunStopReason = "no_usable_result"
    static let permissionApprovalRequired: TaskRunStopReason = "permission_approval_required"
    static let policyBlocked: TaskRunStopReason = "policy_blocked"
    static let policyViolation: TaskRunStopReason = "policy_violation"
    static let providerNoActionableProgress: TaskRunStopReason = "provider_no_actionable_progress"
    static let providerNoSemanticProgress: TaskRunStopReason = "provider_no_semantic_progress"
    static let providerPermissionDeniedAfterApproval: TaskRunStopReason = "provider_permission_denied_after_approval"
    static let providerPermissionDeniedBroadPermissions: TaskRunStopReason = "provider_permission_denied_broad_permissions"
    static let providerPermissionUnresumable: TaskRunStopReason = "provider_permission_unresumable"
    static let repetitionDetected: TaskRunStopReason = "repetition_detected"
    static let superseded: TaskRunStopReason = "superseded"
    static let timeout: TaskRunStopReason = "timeout"
    static let validationContractFailed: TaskRunStopReason = "validation_contract_failed"
    static let workspaceNotFound: TaskRunStopReason = "workspace_not_found"

    var isPolicyBlocked: Bool {
        rawValue.lowercased().contains("policy")
    }
}

extension TaskRun {
    var typedStopReason: TaskRunStopReason? {
        get { TaskRunStopReason(rawValue: stopReason) }
        set { stopReason = newValue?.rawValue ?? "" }
    }
}
