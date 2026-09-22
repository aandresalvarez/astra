import Foundation

/// The dispatch loop's parking mechanism.
///
/// `processQueueLoop` used to sleep a fixed backoff between projections. Its
/// three waits are all "something is busy, try again later", and the events
/// that end them — a dispatched request finishing, a resource lock releasing,
/// the queue stopping — already run on the main actor, so they can say so
/// directly instead of being discovered by the next timer tick. A request that
/// became dispatchable just after a backoff began used to wait out the rest of
/// it; now it does not.
///
/// The old backoff survives as `fallback`, bounding both staleness for changes
/// that carry no signal (a pool resize) and how long cancellation can go
/// unnoticed. Lives beside `TaskQueue` rather than inside it because that file
/// is at its line budget.
@MainActor
extension TaskQueue {
    /// Parked waiter count. Lets a test tell "the loop is parked" from "the
    /// loop has not parked yet" without racing a wake against registration.
    var parkedDispatchWaiterCount: Int { dispatchWaiters.count }

    /// Parks the dispatch loop until queue state plausibly changed, or until
    /// `fallback` elapses.
    func waitForDispatchSignal(fallback: Duration) async {
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dispatchWaiters[waiterID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: fallback)
                self?.resumeDispatchWaiter(waiterID)
            }
        }
    }

    /// Resumes one waiter. Removing it from the dictionary is the claim, so a
    /// continuation is resumed exactly once however many wakes race.
    func resumeDispatchWaiter(_ waiterID: UUID) {
        guard let continuation = dispatchWaiters.removeValue(forKey: waiterID) else { return }
        continuation.resume()
    }

    /// Wakes every parked loop. Worker and lock availability are queue-global,
    /// so a release concerns all of them, not one.
    func wakeDispatchWaiters() {
        #if DEBUG
        TaskQueue.dispatchWakeCountForTesting += 1
        #endif
        let parked = dispatchWaiters
        dispatchWaiters.removeAll()
        for continuation in parked.values { continuation.resume() }
    }

    #if DEBUG
    /// Counts wakes. Whether a given event reaches the loop at all is not
    /// otherwise observable — a wake with nothing parked leaves no trace.
    @MainActor
    static var dispatchWakeCountForTesting = 0
    #endif
}
