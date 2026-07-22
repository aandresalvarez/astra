import Foundation

/// Process-local ownership for scheduler coroutines and completion handles.
/// Durable request state remains in SwiftData; this registry exists only to
/// make cancellation/drain deterministic and prevent model objects from
/// outliving their owning context.
@MainActor
final class ExecutionRequestTaskRegistry {
    struct DrainSnapshot {
        let processing: [Task<Void, Never>]
        let dispatched: [Task<Void, Never>]
        let lifecycle: [Task<Void, Never>]

        func wait() async {
            for task in processing {
                await task.value
            }
            for task in dispatched {
                await task.value
            }
            for task in lifecycle {
                await task.value
            }
        }
    }

    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var dispatchTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var completionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var promisedCompletionRequestIDs: Set<UUID> = []
    private var completedSignals: Set<UUID> = []

    var waitingRequestIDs: [UUID] { Array(promisedCompletionRequestIDs) }
    var ownedTaskCount: Int { processingTasks.count + dispatchTasks.count + lifecycleTasks.count }
    var promisedCompletionCount: Int { promisedCompletionRequestIDs.count }
    var bufferedCompletionSignalCount: Int { completedSignals.count }

    func registerProcessing(_ task: Task<Void, Never>, id: UUID) {
        processingTasks[id] = task
    }

    func finishProcessing(id: UUID) {
        processingTasks.removeValue(forKey: id)
    }

    func registerDispatch(_ task: Task<Void, Never>, requestID: UUID) {
        dispatchTasks[requestID] = task
    }

    func finishDispatch(requestID: UUID) {
        dispatchTasks.removeValue(forKey: requestID)
        complete(requestID: requestID)
    }

    func registerLifecycle(_ task: Task<Void, Never>, id: UUID) {
        lifecycleTasks[id] = task
    }

    func finishLifecycle(id: UUID) {
        lifecycleTasks.removeValue(forKey: id)
    }

    func completionHandle(requestID: UUID) -> Task<Void, Never> {
        promisedCompletionRequestIDs.insert(requestID)
        return Task { @MainActor in
            if completedSignals.remove(requestID) != nil {
                promisedCompletionRequestIDs.remove(requestID)
                return
            }
            let waiterID = UUID()
            await withCheckedContinuation { continuation in
                completionWaiters[requestID, default: [:]][waiterID] = continuation
            }
        }
    }

    func complete(requestID: UUID) {
        guard let waiters = completionWaiters.removeValue(forKey: requestID) else {
            // Dispatches without an awaiting caller are intentionally common.
            // Remember an early signal only when a completion handle was
            // actually promised and has not installed its continuation yet.
            if promisedCompletionRequestIDs.contains(requestID) {
                completedSignals.insert(requestID)
            }
            return
        }
        promisedCompletionRequestIDs.remove(requestID)
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    func drainSnapshot() -> DrainSnapshot {
        DrainSnapshot(
            processing: Array(processingTasks.values),
            dispatched: Array(dispatchTasks.values),
            lifecycle: Array(lifecycleTasks.values)
        )
    }

    func cancelOwnedTasks() {
        for task in processingTasks.values { task.cancel() }
        for task in dispatchTasks.values { task.cancel() }
        for task in lifecycleTasks.values { task.cancel() }
        // Ownership is released only by each task's completion defer. Removing
        // handles here would make a later drain unable to await cancelled work.
    }
}
