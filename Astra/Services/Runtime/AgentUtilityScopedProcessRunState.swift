import Foundation

final class AgentUtilityScopedProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var forcedResult: AgentUtilityRunResult?
    private var cancelled = false

    /// Records a timeout or early-stream result that requires terminating the
    /// process. The continuation must not resume yet: the process reaper still
    /// owns final pipe drain and process-group cleanup.
    func requestTermination(with result: AgentUtilityRunResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, !cancelled, forcedResult == nil else { return false }
        forcedResult = result
        return true
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Completes only after AgentExecutionScopedProcess has reaped the child.
    /// A timeout/early-stream result wins over the child's signal exit status.
    func completeAfterProcessExit(naturalResult: AgentUtilityRunResult) -> AgentUtilityRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        return forcedResult ?? naturalResult
    }

    /// Launch failures have no child to reap, so they can complete directly.
    func completeWithoutProcess(_ result: AgentUtilityRunResult) -> AgentUtilityRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        return result
    }
}
