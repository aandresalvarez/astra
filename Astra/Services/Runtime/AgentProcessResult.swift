import Foundation

struct AgentProcessResult {
    let exitCode: Int
    let error: String?
    let providerFailureOutput: String?
    let providerVersion: String?
    let policyViolation: Bool
    let policyViolationMessage: String?
    let policyApprovalRequired: Bool
    let policyApprovalMessage: String?
    let runtimeStopReason: String?
    let runtimeStopMessage: String?
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
