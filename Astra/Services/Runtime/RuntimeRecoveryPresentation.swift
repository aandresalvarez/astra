import SwiftData
import ASTRAModels

/// Read-only presentation of the protected execution owner. UI approval cannot
/// substitute for a cleanup receipt or mutate recovery authority.
enum RuntimeRecoveryPresentation {
    @MainActor static func blockedMessage(task: AgentTask, context: ModelContext) -> String? {
        guard task.status != .running else { return nil }
        do {
            guard let record = try RuntimeExecutionOwner.existing(task: task, context: context) else {
                return RuntimeExecutionOwner.requiresExistingReceipt(task)
                    ? "The saved execution receipt is missing. ASTRA cannot verify that earlier work stopped, so new work and recovery are blocked."
                    : nil
            }
            if RuntimeCompletedUserTurnContinuation.hasSettledTurn(record, task: task, context: context)
                || RuntimeCompletedUserTurnContinuation.hasUnlaunchedPreparation(record, task: task, context: context) { return nil }
            // Historical resource release is not authority to retry this task.
            guard !record.canReplace, !record.canRecoverPreparation else { return providerResourceMessage(task: task) }
            let inspection = try RuntimeExecutionOwner.inspection(task: task, context: context)
            // A connected interactive ask retains its normal permission UI.
            guard inspection?.canReconnect != true else { return nil }
            return inspection?.message
        } catch {
            return "The saved execution owner could not be read. New work remains blocked until its state can be verified."
        }
    }

    /// The latest run records why this task never launched. A manual check can
    /// re-evaluate the gate, but rendering the explanation never retries it.
    @MainActor private static func providerResourceMessage(task: AgentTask) -> String? {
        guard let run = task.runs.max(by: { $0.startedAt < $1.startedAt }),
              run.status == .failed,
              run.stopReason == RuntimeProviderResourceRegistry.Block.stopReason else { return nil }
        return task.events.filter { $0.run?.id == run.id && $0.type == "error" }
            .max(by: { $0.timestamp < $1.timestamp })?.payload
    }

    /// A live permission request keeps priority over a queued message. When
    /// recovery is blocked, that permission belongs to an execution we cannot
    /// reconnect to; preserve the saved message's cancellation controls instead.
    static func queuedRequestDock(
        _ waiting: TaskDecisionDockPresentation?,
        hasOpenApprovalRequest: Bool,
        blockedMessage: String?
    ) -> TaskDecisionDockPresentation? {
        guard let waiting, !hasOpenApprovalRequest || blockedMessage != nil else { return nil }
        return waitingDock(waiting, blockedMessage: blockedMessage)
    }

    /// Keep the saved request's cancellation controls while explaining why its
    /// admission cannot proceed. The journal remains the only launch authority.
    static func waitingDock(_ waiting: TaskDecisionDockPresentation, blockedMessage: String?) -> TaskDecisionDockPresentation {
        guard let blockedMessage else { return waiting }
        var presentation = waiting
        presentation.title = "Recovery blocked"
        presentation.icon = "lock.fill"
        presentation.tone = .attention
        presentation.summary = "Your message is saved. " + blockedMessage
        presentation.compactMeta = "Previous execution unverified"
        presentation.details.insert(.init(id: "recovery-blocked", title: "Why this request waits",
            summary: blockedMessage, systemImage: "lock.fill", tone: .attention), at: 0)
        return presentation
    }
}
