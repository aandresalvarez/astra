import Foundation

/// A runner owns both pending launch checks and its live process. Cancelling
/// invalidates pending checks, without permanently cancelling a later launch.
final class RuntimeHomeAccessCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func snapshot() -> UInt64 { lock.withLock { generation } }
    func invalidate() { lock.withLock { generation &+= 1 } }
    func isCurrent(_ snapshot: UInt64) -> Bool { lock.withLock { generation == snapshot } }
}
