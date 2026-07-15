import Foundation

struct AgentProcessResult {
    let exitCode: Int
    let error: String?
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
        self.exitCode = terminatedAfterTerminalProgress ? 0 : exitCode
        self.error = error
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
}
