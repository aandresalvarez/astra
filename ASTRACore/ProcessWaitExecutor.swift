import Foundation

/// A child may wait for work that finishes only after another child is reaped.
/// Blocking a shared Swift or Dispatch pool can queue that second reap behind
/// the first. Each wait therefore owns a thread, released when the wait ends.
public enum ProcessWaitExecutor {
    public static func submit(_ wait: @escaping @Sendable () -> Void) {
        let thread = Thread(block: wait)
        thread.name = "ASTRA process wait"
        thread.qualityOfService = .utility
        thread.start()
    }
}
