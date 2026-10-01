import Foundation
import ASTRACore
import ASTRAModels

/// Process-local tracking derived from successful response writes. Durable
/// acknowledgement is recorded only after the provider emits its terminal result.
/// A write and terminal-result observation share a lock so a fast result cannot
/// overtake registration of its receipt.
final class AgentLivePermissionDeliveryChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var providerTurnCompleted = false
    private var writtenApprovalRequestIDs: Set<String> = []
    private var receipts: [@Sendable () async -> Void] = []

    @discardableResult
    func writeResponse(_ response: String, to process: AgentExecutionScopedProcess,
                       requestID: String? = nil, outcome: InteractiveAskOutcome) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !providerTurnCompleted, process.writeStdinLine(response) else { return false }
        if case .allowWithAcknowledgementReceipt(let receipt) = outcome {
            receipts.append(receipt)
        }
        if outcome.isAllowed, let requestID { writtenApprovalRequestIDs.insert(requestID) }
        return true
    }

    func observeProviderCompletion() {
        lock.lock()
        defer { lock.unlock() }
        providerTurnCompleted = true
    }

    var acknowledgedPermissionRequestIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return providerTurnCompleted ? writtenApprovalRequestIDs : []
    }

    var writtenPermissionRequestIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return writtenApprovalRequestIDs
    }

    /// Called after final stdout drain and before the worker settles the run.
    /// Exit codes, stream noise, and local decisions cannot acknowledge a turn.
    func recordAcknowledgements() async {
        for receipt in takeAcknowledgedReceipts() { await receipt() }
    }

    private func takeAcknowledgedReceipts() -> [@Sendable () async -> Void] {
        lock.lock()
        defer { lock.unlock() }
        defer { receipts.removeAll() }
        return providerTurnCompleted ? receipts : []
    }
}

extension AgentRuntimeProcessRunner {
    /// Answers a provider control request. `can_use_tool` asks are routed to the
    /// worker's hook (which surfaces them in the UI and awaits the user); every
    /// other subtype gets an immediate error response so the provider never
    /// blocks on an unanswered request. A heartbeat keeps the idle watchdog from
    /// killing the run while the user decides.
    static func answerControlRequest(
        _ control: ClaudeControlProtocol.ControlRequest,
        process: AgentExecutionScopedProcess,
        monitor: AgentProcessMonitor,
        taskID: UUID,
        deliveryChannel: AgentLivePermissionDeliveryChannel,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?
    ) {
        guard control.subtype == "can_use_tool", let onInteractiveAsk else {
            if let response = ClaudeControlProtocol.errorResponse(
                requestID: control.requestID,
                message: "ASTRA does not handle control requests of subtype \(control.subtype)."
            ) {
                process.writeStdinLine(response)
            }
            return
        }
        let request = AgentInteractiveAskRequest(
            requestID: control.requestID,
            toolName: control.toolName ?? "Tool",
            inputSummary: control.inputSummary,
            commandText: control.commandText,
            pathText: control.pathText
        )
        let heartbeat = Task.detached {
            while !Task.isCancelled {
                monitor.recordActivity()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        Task.detached {
            let outcome = await onInteractiveAsk(request)
            heartbeat.cancel()
            monitor.recordActivity()
            let response: String?
            switch outcome {
            case .allow, .allowWithAcknowledgementReceipt:
                response = ClaudeControlProtocol.allowResponse(for: control)
            case .deny(let message):
                response = ClaudeControlProtocol.denyResponse(for: control, message: message)
            }
            if let response { deliveryChannel.writeResponse(response, to: process, requestID: control.requestID, outcome: outcome) }
        }
    }

}
