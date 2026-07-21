import Foundation

/// Process-local ownership for scheduler coroutines and completion handles.
/// Durable request state remains in SwiftData; this registry exists only to
/// make cancellation/drain deterministic and prevent model objects from
/// outliving their owning context.
@MainActor
final class ExecutionRequestTaskRegistry {
    struct DrainSnapshot {
        let processing: Task<Void, Never>?
        let dispatched: [Task<Void, Never>]

        func wait() async {
            await processing?.value
            for task in dispatched {
                await task.value
            }
        }
    }

    private var processingTask: Task<Void, Never>?
    private var dispatchTasks: [UUID: Task<Void, Never>] = [:]
    private var completionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var completedSignals: Set<UUID> = []

    var waitingRequestIDs: [UUID] { Array(completionWaiters.keys) }

    func registerProcessing(_ task: Task<Void, Never>) {
        processingTask = task
    }

    func finishProcessing() {
        processingTask = nil
    }

    func registerDispatch(_ task: Task<Void, Never>, requestID: UUID) {
        dispatchTasks[requestID] = task
    }

    func finishDispatch(requestID: UUID) {
        dispatchTasks.removeValue(forKey: requestID)
        complete(requestID: requestID)
    }

    func completionHandle(requestID: UUID) -> Task<Void, Never> {
        Task { @MainActor in
            if completedSignals.remove(requestID) != nil { return }
            let waiterID = UUID()
            await withCheckedContinuation { continuation in
                completionWaiters[requestID, default: [:]][waiterID] = continuation
            }
        }
    }

    func complete(requestID: UUID) {
        guard let waiters = completionWaiters.removeValue(forKey: requestID) else {
            completedSignals.insert(requestID)
            return
        }
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    func drainSnapshot() -> DrainSnapshot {
        DrainSnapshot(processing: processingTask, dispatched: Array(dispatchTasks.values))
    }

    func cancelOwnedTasks() {
        processingTask?.cancel()
        for task in dispatchTasks.values { task.cancel() }
        dispatchTasks.removeAll()
    }
}
