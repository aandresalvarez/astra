import Foundation
import ASTRACore

struct AgentProcessResult: Codable {
    var executionStopProof: RuntimeExecutionStopProof?
    var executionTurnsSpent: Int?
    var executionTokensSpent: Int?
    var executionSecondsSpent: TimeInterval?
    /// Conservative utility-token allocation, separately audited by supervision events.
    var supervisionReservedTokens: Int?
    /// Successfully written approval responses followed by provider completion.
    /// Receipt-save failures must not erase this process-local evidence.
    var acknowledgedPermissionRequestIDs: Set<String> = []
    /// Written responses without a terminal frame are uncertain, not safe retries.
    var writtenPermissionRequestIDs: Set<String> = []
    let exitCode: Int
    let error: String?
    let providerFailureOutput: String?
    let providerVersion: String?
    let policyViolation: Bool
    let policyViolationMessage: String?
    let policyApprovalRequired: Bool
    let policyApprovalMessage: String?
    var runtimeStopReason: String?
    var runtimeStopMessage: String?
    let runtimeRepairContext: RuntimeRepairContext?
    let budgetExceeded: Bool
    let budgetWarning: Bool
    let finalReportedBudgetExceededAfterCompletion: Bool
    let terminatedAfterTerminalProgress: Bool
    let timedOut: Bool
    let repetitionKilled: Bool
    let maxTurnsExceeded: Bool
    let readOnlyBoundaryEvidence: ReadOnlyBoundaryEvidence?

    init(
        exitCode: Int,
        error: String? = nil,
        providerFailureOutput: String? = nil,
        providerVersion: String? = nil,
        policyViolation: Bool = false,
        policyViolationMessage: String? = nil,
        policyApprovalRequired: Bool = false,
        policyApprovalMessage: String? = nil,
        runtimeStopReason: String? = nil,
        runtimeStopMessage: String? = nil,
        runtimeRepairContext: RuntimeRepairContext? = nil,
        budgetExceeded: Bool = false,
        budgetWarning: Bool = false,
        finalReportedBudgetExceededAfterCompletion: Bool = false,
        terminatedAfterTerminalProgress: Bool = false,
        timedOut: Bool = false,
        repetitionKilled: Bool = false,
        maxTurnsExceeded: Bool = false,
        readOnlyBoundaryEvidence: ReadOnlyBoundaryEvidence? = nil
    ) {
        // ASTRA reaped a provider that had finished its turn and was only
        // holding the pipe open, so the SIGTERM's own status would libel a run
        // that succeeded. This is sound only because the reap now demands both
        // a genuine terminal frame and a quiet grace window; when it fired on
        // time alone, this line is what dressed a mid-work kill up as a clean
        // completion and kept the truncation invisible.
        self.exitCode = terminatedAfterTerminalProgress ? 0 : exitCode
        self.error = error
        self.providerFailureOutput = providerFailureOutput
        self.providerVersion = providerVersion
        self.policyViolation = policyViolation
        self.policyViolationMessage = policyViolationMessage
        self.policyApprovalRequired = policyApprovalRequired
        self.policyApprovalMessage = policyApprovalMessage
        self.runtimeStopReason = runtimeStopReason
        self.runtimeStopMessage = runtimeStopMessage
        self.runtimeRepairContext = runtimeRepairContext
        self.budgetExceeded = budgetExceeded
        self.budgetWarning = budgetWarning
        self.finalReportedBudgetExceededAfterCompletion = finalReportedBudgetExceededAfterCompletion
        self.terminatedAfterTerminalProgress = terminatedAfterTerminalProgress
        self.timedOut = timedOut
        self.repetitionKilled = repetitionKilled
        self.maxTurnsExceeded = maxTurnsExceeded
        self.readOnlyBoundaryEvidence = readOnlyBoundaryEvidence
    }

    var runtimeStopped: Bool {
        runtimeStopReason?.isEmpty == false
    }

    /// Called after the ordered ownership queue drains. Late evidence may
    /// invalidate tool cleanup while preserving process facts and accounting.
    func applyingOwnershipObservations(nativeSessionFailure: String?, supervisionTokens: Int?,
                                       acknowledgedPermissions: Set<String>, writtenPermissions: Set<String>) -> Self {
        var result = self
        if let nativeSessionFailure {
            result.runtimeStopReason = "runtime_recovery_blocked"
            result.runtimeStopMessage = nativeSessionFailure
            if let proof = result.executionStopProof {
                result.executionStopProof = .init(executionID: proof.executionID, process: proof.process,
                    reaped: proof.reaped, processGroupEmpty: proof.processGroupEmpty, toolsStopped: false,
                    remoteWorkExcluded: proof.remoteWorkExcluded, capturedAt: proof.capturedAt)
            }
        }
        result.supervisionReservedTokens = supervisionTokens
        result.acknowledgedPermissionRequestIDs = acknowledgedPermissions
        result.writtenPermissionRequestIDs = writtenPermissions
        return result
    }

    /// ASTRA ended the provider itself: a watchdog or other runtime stop, the
    /// idle timeout, a policy stop or approval pause, the token budget, the
    /// turn limit, or a repetition kill. Some of these close stdin first and
    /// let the provider exit 0, so the exit code alone does not say the turn
    /// finished. A reap after the turn's terminal frame is not one of them:
    /// the turn had already ended, and it reads as exit 0.
    var stoppedByASTRA: Bool {
        runtimeStopped || timedOut || policyViolation || policyApprovalRequired
            || budgetExceeded || maxTurnsExceeded || repetitionKilled
    }
}
