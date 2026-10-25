import Foundation

/// Utilities inherit the settlement owner before touching provider settings.
/// The actor/kernel lease serializes live writers; the journal retains any
/// uncertain cancellation after that temporary lease is released.
@MainActor
final class RuntimeUtilitySharedStateLease {
    private let owner: RuntimeExecutionOwner?
    private let lease: AgentRuntimeSharedStateLease
    private let gate: AgentRuntimeSharedStateGate

    private init(owner: RuntimeExecutionOwner?, lease: AgentRuntimeSharedStateLease, gate: AgentRuntimeSharedStateGate) {
        self.owner = owner
        self.lease = lease
        self.gate = gate
    }

    static func acquire(_ key: AgentRuntimeSharedStateKey, gate: AgentRuntimeSharedStateGate = .shared) async throws -> RuntimeUtilitySharedStateLease {
        let owner = RuntimeSettlementExecutionScope.current?.executionOwner
        let lease = try await gate.acquire(key, owner: owner)
        return RuntimeUtilitySharedStateLease(owner: owner, lease: lease, gate: gate)
    }

    func release() async {
        // A failed/uncertain write leaves the durable key reserved. Every next
        // acquirer checks that journal, including after an ASTRA restart.
        _ = owner?.releaseProviderSharedState()
        await gate.release(lease)
    }
}
