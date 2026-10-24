import Foundation

/// The durable owner fences the whole settlement before this scope exists.
/// Child receipts only narrow that fence after the awaited work has returned.
/// A crash loses this object, never the persisted in-progress barrier.
final class RuntimeSettlementExecutionScope: @unchecked Sendable {
    @TaskLocal static var current: RuntimeSettlementExecutionScope?
    private let lock = NSLock()
    private var children: [UUID: Bool] = [:]
    private var sealed = false
    let mayLaunch: Bool
    init(mayLaunch: Bool) { self.mayLaunch = mayLaunch }
    func begin(_ id: UUID) throws {
        try lock.withLock {
            guard mayLaunch, !sealed else { throw RuntimeExecutionOwnerStore.Failure.busy }
            children[id] = false
        }
    }
    func didNotLaunch(_ id: UUID) { _ = lock.withLock { children.removeValue(forKey: id) } }
    func stopped(_ id: UUID, proof: RuntimeExecutionStopProof?) {
        let stopped = proof?.reaped == true && proof?.processGroupEmpty == true && proof?.process.presence == .absent
        lock.withLock { children[id] = stopped }
    }
    func seal() { lock.withLock { sealed = true } }
    var localWorkStopped: Bool { lock.withLock { children.values.allSatisfy { $0 } } }
    // Test commands and validators can launch detached or remote work. Their
    // successful return certifies no such work, even if the local group is gone.
    var toolsStopped: Bool { lock.withLock { children.isEmpty } }
}
