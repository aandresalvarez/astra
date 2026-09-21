import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The dispatch loop used to sleep a fixed backoff between projections. It now
/// parks until something it is waiting for actually frees up, with the old
/// backoff kept only as a fallback.
///
/// Two deliberate choices here. Waits are budgeted in polls, never in elapsed
/// time: these run under a full parallel suite, where a wall-clock bound
/// measures host load rather than the queue. And the fallbacks are kept short
/// so that a regression fails fast instead of parking a main-actor task for
/// the rest of the run — which is why the load-bearing assertion is the
/// synchronous waiter count right after the wake, not the resumption itself.
/// A broken wake leaves that count non-zero immediately.
@Suite("Dispatch loop waits on a signal", .serialized)
@MainActor
struct TaskQueueDispatchSignalTests {
    /// Lets a parked task report that it resumed, without a wall clock.
    @MainActor private final class Resumption {
        var happened = false
    }

    @Test("A wake claims and resumes a parked loop")
    func wakeResumesParkedLoop() async {
        let queue = TaskQueue(poolSize: 1)
        let resumption = Resumption()
        _ = Task { @MainActor in
            await queue.waitForDispatchSignal(fallback: .milliseconds(200))
            resumption.happened = true
        }
        #expect(await parkedWaiterAppears(on: queue), "the loop must register before being signalled")

        queue.wakeDispatchWaiters()

        // The teeth: the wake claims the waiter synchronously. A wake that
        // failed to would leave it parked here, whatever the fallback later does.
        #expect(queue.parkedDispatchWaiterCount == 0)
        #expect(await pollUntil { resumption.happened }, "the claimed waiter must actually resume")
    }

    @Test("The fallback still ends a wait that nothing signals")
    func fallbackEndsAnUnsignalledWait() async {
        let queue = TaskQueue(poolSize: 1)

        // A pool resize carries no signal, so the fallback is the only way out.
        await queue.waitForDispatchSignal(fallback: .milliseconds(1))

        #expect(queue.parkedDispatchWaiterCount == 0)
    }

    @Test("A wake releases every parked loop, not just the first")
    func wakeReleasesEveryParkedLoop() async {
        let queue = TaskQueue(poolSize: 3)
        let resumptions = (0..<3).map { _ in Resumption() }
        for resumption in resumptions {
            _ = Task { @MainActor in
                await queue.waitForDispatchSignal(fallback: .milliseconds(200))
                resumption.happened = true
            }
        }
        #expect(await parkedWaiterAppears(on: queue, count: 3))

        queue.wakeDispatchWaiters()

        #expect(queue.parkedDispatchWaiterCount == 0)
        #expect(await pollUntil { resumptions.allSatisfy(\.happened) })
    }

    @Test("Waking an idle queue is a no-op rather than a crash")
    func wakingAnIdleQueueIsHarmless() {
        let queue = TaskQueue(poolSize: 1)
        queue.wakeDispatchWaiters()
        queue.wakeDispatchWaiters()
        #expect(queue.parkedDispatchWaiterCount == 0)
    }

    /// Yields until the expected waiters have registered, so the wake is never
    /// racing registration. Counting polls, not seconds.
    private func parkedWaiterAppears(
        on queue: TaskQueue,
        count: Int = 1,
        polls: Int = 3_000
    ) async -> Bool {
        await pollUntil(polls: polls) { queue.parkedDispatchWaiterCount >= count }
    }

    private func pollUntil(polls: Int = 3_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<polls {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
