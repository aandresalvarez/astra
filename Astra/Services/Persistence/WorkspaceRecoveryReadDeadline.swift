import Foundation

/// Bounds a read-only recovery probe even when a filesystem syscall ignores
/// task cancellation. A late result cannot reach the importing main actor.
/// Callers must capture only Sendable values, never a ModelContext or models.
enum WorkspaceRecoveryReadDeadline {
    static func read<Value: Sendable>(
        timeout: Duration?,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let race = RecoveryReadRace<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation: continuation, timeout: timeout, operation: operation)
            }
        } onCancel: {
            race.finish(nil)
        }
    }
}

private final class RecoveryReadRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var continuation: CheckedContinuation<Value?, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(continuation: CheckedContinuation<Value?, Never>, timeout: Duration?,
               operation: @escaping @Sendable () async -> Value) {
        lock.lock()
        guard !resolved else { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation
        lock.unlock()
        let worker = Task.detached(priority: .utility) { [self] in
            guard !Task.isCancelled else { return }
            finish(await operation())
        }
        let timer: Task<Void, Never>? = timeout.map { duration in
            Task.detached(priority: .utility) { [self] in
                do { try await Task.sleep(for: duration) } catch { return }
                finish(nil)
            }
        }
        lock.lock()
        if resolved {
            lock.unlock()
            worker.cancel()
            timer?.cancel()
        } else {
            self.worker = worker
            self.timer = timer
            lock.unlock()
        }
    }

    func finish(_ value: Value?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        let worker = self.worker
        let timer = self.timer
        self.continuation = nil
        self.worker = nil
        self.timer = nil
        lock.unlock()
        // Cancellation is advisory; never join a blocked filesystem probe.
        worker?.cancel()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
