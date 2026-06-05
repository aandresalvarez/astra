import Foundation

/// Thread-safe collector for fire-and-forget `Task` handles.
/// Allows callers to drain all pending tasks before proceeding.
final class PendingTaskCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return tasks.count
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }; tasks.append(task)
    }

    private func takeSnapshot() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }; return tasks
    }

    func drainAll() async {
        for task in takeSnapshot() {
            await task.value
        }
    }
}

/// Serializes main-actor event recording while still allowing runtime readers to
/// enqueue work immediately from background pipe callbacks.
final class OrderedMainActorTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var tail: Task<Void, Never>?

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return tasks.count
    }

    func add(_ operation: @escaping @MainActor () -> Void) {
        lock.lock()
        let previous = tail
        let task = Task { @MainActor in
            if let previous {
                await previous.value
            }
            operation()
        }
        tasks.append(task)
        tail = task
        lock.unlock()
    }

    private func takeTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    func drainAll() async {
        await takeTail()?.value
    }
}
