import Foundation

public struct TaskRunStopReason: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func custom(_ rawValue: String) -> TaskRunStopReason? {
        TaskRunStopReason(rawValue: rawValue)
    }

    public static let appRestarted: TaskRunStopReason = "app_restarted"
    public static let browserActionBudgetExceeded: TaskRunStopReason = "browser_action_budget_exceeded"
    public static let cancelled: TaskRunStopReason = "cancelled"
    public static let capabilityRuntimeResourcesMissing: TaskRunStopReason = "capability_runtime_resources_missing"
    public static let completed: TaskRunStopReason = "completed"
    public static let connectorPreflightFailed: TaskRunStopReason = "connector_preflight_failed"
    public static let credentialProjectionRequired: TaskRunStopReason = "credential_projection_required"
    public static let deliverableVerificationFailed: TaskRunStopReason = "deliverable_verification_failed"
    public static let dockerDaemonUnavailable: TaskRunStopReason = "docker_daemon_unavailable"
    public static let dockerContextUnapproved: TaskRunStopReason = "docker_context_unapproved"
    public static let dockerImageUnavailable: TaskRunStopReason = "docker_image_unavailable"
    public static let dockerLaunchFailed: TaskRunStopReason = "docker_launch_failed"
    public static let dockerMountFailed: TaskRunStopReason = "docker_mount_failed"
    public static let dockerProviderExecutableMissing: TaskRunStopReason = "docker_provider_executable_missing"
    public static let failed: TaskRunStopReason = "failed"
    public static let inferredValidationFailed: TaskRunStopReason = "inferred_validation_failed"
    public static let isolationFailed: TaskRunStopReason = "isolation_failed"
    public static let maxBudgetReached: TaskRunStopReason = "max_budget_reached"
    public static let maxTurnsReached: TaskRunStopReason = "max_turns_reached"
    public static let noUsableResult: TaskRunStopReason = "no_usable_result"
    public static let permissionApprovalRequired: TaskRunStopReason = "permission_approval_required"
    public static let policyBlocked: TaskRunStopReason = "policy_blocked"
    public static let policyViolation: TaskRunStopReason = "policy_violation"
    public static let providerNoActionableProgress: TaskRunStopReason = "provider_no_actionable_progress"
    public static let providerNoSemanticProgress: TaskRunStopReason = "provider_no_semantic_progress"
    public static let providerSemanticProgressStalled: TaskRunStopReason = "provider_semantic_progress_stalled"
    public static let providerActiveToolStalled: TaskRunStopReason = "provider_active_tool_stalled"
    public static let providerWorkspaceJobStalled: TaskRunStopReason = "provider_workspace_job_stalled"
    public static let providerPermissionDeniedAfterApproval: TaskRunStopReason = "provider_permission_denied_after_approval"
    public static let providerPermissionDeniedBroadPermissions: TaskRunStopReason = "provider_permission_denied_broad_permissions"
    public static let providerPermissionUnresumable: TaskRunStopReason = "provider_permission_unresumable"
    public static let repetitionDetected: TaskRunStopReason = "repetition_detected"
    /// Set by `TaskRuntimeCompatibilityService.launchBlock` when a task's
    /// explicitly-selected runtime can't satisfy its required ASTRA
    /// capabilities (host-control MCP, Docker workspace shell, browser
    /// control) and there's no automatic fallback to reroute to silently.
    public static let runtimeCapabilityIncompatible: TaskRunStopReason = "runtime_capability_incompatible"
    public static let superseded: TaskRunStopReason = "superseded"
    public static let timeout: TaskRunStopReason = "timeout"
    public static let validationContractFailed: TaskRunStopReason = "validation_contract_failed"
    public static let workspaceNotFound: TaskRunStopReason = "workspace_not_found"

    /// True for stop reasons where the run was blocked before completing —
    /// either an explicit policy diagnostic or a pre-launch runtime
    /// incompatibility — as opposed to a run that started and then failed,
    /// timed out, or was cancelled. A closed set rather than a substring
    /// match on `rawValue`, so a new stop reason must opt in explicitly
    /// instead of silently matching (or missing) based on its spelling.
    public var isPolicyBlocked: Bool {
        self == .policyBlocked || self == .policyViolation || self == .runtimeCapabilityIncompatible
    }

    public var isDockerRuntimeBlocked: Bool {
        rawValue.lowercased().hasPrefix("docker_")
    }
}

extension TaskRun {
    public var typedStopReason: TaskRunStopReason? {
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
public enum TaskRunOutputCap {
    /// Bytes kept from the start of the output.
    public static let headByteLimit = 256 * 1024
    /// Bytes kept from the end of the output.
    public static let tailByteLimit = 256 * 1024

    public static let elisionMarker = "\n\n\u{2026} [ASTRA: output truncated to keep the run record bounded \u{2014} full output preserved in session history] \u{2026}\n\n"

    /// Returns `output` unchanged when it is within the combined head+tail budget,
    /// otherwise the first `headByteLimit` UTF-8 bytes + marker + last
    /// `tailByteLimit` UTF-8 bytes. Idempotent: the result is below the
    /// `headByteLimit + tailByteLimit` threshold, so re-applying never
    /// re-truncates a string this function produced. Splits only on UTF-8 scalar
    /// boundaries so no multi-byte character is corrupted.
    public static func capped(_ output: String) -> String {
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
        // `Data` is copy-on-write, so this shares storage with `slice` until the
        // first trim mutation — no eager copy. The fallback below still reads
        // the original `slice`.
        var data = slice
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
