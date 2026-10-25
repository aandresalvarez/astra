import Foundation

/// The durable owner fences the whole settlement before this scope exists.
/// Child receipts only narrow that fence after the awaited work has returned.
/// A crash loses this object, never the persisted in-progress barrier.
final class RuntimeSettlementExecutionScope: @unchecked Sendable {
    @TaskLocal static var current: RuntimeSettlementExecutionScope?
    @MainActor weak var executionOwner: RuntimeExecutionOwner?
    private let lock = NSLock()
    private var children: [UUID: Bool] = [:]
    private var sealed = false
    private var cancelled = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    let mayLaunch: Bool
    init(mayLaunch: Bool) { self.mayLaunch = mayLaunch }
    func begin(_ id: UUID, cancel: @escaping @Sendable () -> Void = {}) throws {
        try lock.withLock {
            guard mayLaunch, !sealed, !cancelled else { throw RuntimeExecutionOwnerStore.Failure.busy }
            children[id] = false
            cancellations[id] = cancel
        }
    }
    func didNotLaunch(_ id: UUID) { lock.withLock { children.removeValue(forKey: id); cancellations.removeValue(forKey: id) } }
    func cancel() {
        let operations = lock.withLock { cancelled = true; return Array(cancellations.values) }
        operations.forEach { $0() }
    }
    func stopped(_ id: UUID, proof: RuntimeExecutionStopProof?) {
        let stopped = proof?.reaped == true && proof?.processGroupEmpty == true && proof?.process.presence == .absent
        lock.withLock { children[id] = stopped; cancellations.removeValue(forKey: id) }
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func seal() { lock.withLock { sealed = true } }
    var localWorkStopped: Bool { lock.withLock { children.values.allSatisfy { $0 } } }
    // Test commands and validators can launch detached or remote work. Their
    // successful return certifies no such work, even if the local group is gone.
    var toolsStopped: Bool { lock.withLock { children.isEmpty } }
}
