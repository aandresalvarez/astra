import Foundation

/// Scoped limits inherited by all utility adapters. Normal utility calls keep
/// their existing behavior; supervision uses a bounded, separate subprocess.
enum AgentUtilityExecutionLimits {
    @TaskLocal static var maximumOutputBytes: Int?
    @TaskLocal static var requiresIsolation = false
}

final class AgentUtilityOutputAllowance: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    init(_ limit: Int?) { remaining = limit.map { max(0, $0) } }
    func accept(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let remaining else { return true }
        guard count <= remaining else { self.remaining = 0; return false }
        self.remaining = remaining - count
        return true
    }
}
