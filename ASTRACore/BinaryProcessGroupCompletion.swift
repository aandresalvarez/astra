import Darwin
import Foundation

/// Evidence for task-owned preparation probes. Deadlines bound the join; only
/// a completed launch plus waitpid and an absent group constitute success.
final class BinaryProcessGroupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var launchComplete = false
    private var pid: pid_t?
    private var didReap = false

    func launched(_ pid: pid_t) { lock.withLock { self.pid = pid } }
    func launchFinished() { lock.withLock { launchComplete = true } }
    func reaped() { lock.withLock { didReap = true } }

    private var stopped: Bool {
        lock.withLock {
            guard launchComplete else { return false }
            guard let pid else { return true } // launch never crossed spawn
            return didReap && kill(-pid, 0) == -1 && errno == ESRCH
        }
    }

    func waitForStop() async -> Bool {
        // Caller cancellation must not cancel the evidence collection itself.
        await Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !self.stopped && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return self.stopped
        }.value
    }
}
