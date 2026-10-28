import Foundation

/// The worker owns the consumer. A retired producer is never reused, and may
/// only deliver an ignored result; it cannot re-enter worker settlement.
@MainActor
final class RuntimeProviderWait {
    let owner: RuntimeExecutionOwner
    private(set) var retired = false
    // Producer completion can outlive the retired consumer.
    private(set) var producer: Task<Void, Never>?
    private var continuation: CheckedContinuation<AgentProcessResult, Never>?

    init(owner: RuntimeExecutionOwner) { self.owner = owner }

    func run(_ operation: @escaping @MainActor () async -> AgentProcessResult) async -> AgentProcessResult {
        await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            self.continuation = continuation
            producer = Task { @MainActor in
                let result = await operation()
                guard !self.retired else { return }
                self.continuation?.resume(returning: result)
                self.continuation = nil
            }
          }
        } onCancel: { Task { @MainActor in self.cancelProducer() } }
    }

    func cancelProducer() { producer?.cancel() }

    func retire(generation: UUID) -> Bool {
        guard !retired, continuation != nil, owner.isActive,
              owner.record.ownerID == generation, owner.record.cancellationRequested == true,
              owner.record.canReplace else { return false }
        retired = true
        continuation?.resume(returning: AgentProcessResult(exitCode: -1,
            runtimeStopReason: "cancelled", runtimeStopMessage: "Cancelled execution cleanup was verified."))
        continuation = nil
        return true
    }
}
