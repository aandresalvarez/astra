import Foundation

struct TaskRunStopReason: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    let rawValue: String

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Bounds the inline `TaskRun.output` blob so a runaway-output run can't bloat
/// the SwiftData store / memory indefinitely. We intentionally do NOT use
/// `@Attribute(.externalStorage)` (that would force a schema migration); instead
/// we keep a generous head + tail with an elision marker and apply it only when a
/// run is finalized — never on the live streaming append path, so the in-flight
/// transcript the user is watching is left untouched.
enum TaskRunOutputCap {
    /// Bytes kept from the start of the output.
    static let headByteLimit = 256 * 1024
    /// Bytes kept from the end of the output.
    static let tailByteLimit = 256 * 1024

    static let elisionMarker = "\n\n\u{2026} [ASTRA: output truncated to keep the run record bounded \u{2014} full output preserved in session history] \u{2026}\n\n"

    /// Returns `output` unchanged when it is within the combined head+tail budget,
    /// otherwise the first `headByteLimit` UTF-8 bytes + marker + last
    /// `tailByteLimit` UTF-8 bytes. Idempotent: the result is below the
    /// `headByteLimit + tailByteLimit` threshold, so re-applying never
    /// re-truncates a string this function produced. Splits only on UTF-8 scalar
    /// boundaries so no multi-byte character is corrupted.
    static func capped(_ output: String) -> String {
        let utf8 = output.utf8
        let total = utf8.count
        guard total > headByteLimit + tailByteLimit else { return output }

        // Materialize only the head and tail byte slices, never the whole
        // output as a second buffer — capping a multi-MB run at finalize time
        // should reduce peak memory, not double it. `String.UTF8View` is
        // bidirectional, so `suffix` walks back `tailByteLimit` bytes from the
        // end rather than scanning the full string.
        let head = decodeOnScalarBoundary(Data(utf8.prefix(headByteLimit)), preferTrailingTrim: true)
        let tail = decodeOnScalarBoundary(Data(utf8.suffix(tailByteLimit)), preferTrailingTrim: false)
        return head + elisionMarker + tail
    }

    /// Decodes a UTF-8 byte slice that may have been cut mid-scalar. When
    /// `preferTrailingTrim` is true we drop up to 3 trailing bytes (the head was
    /// cut at its end); otherwise we drop up to 3 leading bytes (the tail was cut
    /// at its start). Falls back to a lossy decode only if trimming cannot
    /// produce valid UTF-8.
    private static func decodeOnScalarBoundary(_ slice: Data, preferTrailingTrim: Bool) -> String {
        var data = Data(slice)
        for _ in 0..<4 {
            if let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            if data.isEmpty { break }
            if preferTrailingTrim {
                data.removeLast()
            } else {
                data.removeFirst()
            }
        }
        return String(decoding: slice, as: UTF8.self)
    }
}
