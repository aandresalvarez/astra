import Foundation
import Testing
@testable import ASTRA

/// Holds the shape of the sidebar's rebuild window.
///
/// Production logged 5,611 index builds in one session, 47% of them landing
/// under a second after the previous one, because `taskActivitySignature` moves
/// on every turn-request write and each move ran a full rebuild inside
/// `withAnimation`. The window has to collapse those without delaying the first
/// change after a quiet stretch — a run starting should animate in on the next
/// turn, not a quarter second later.
///
/// Timing is asserted by polling rather than by sleeping a fixed budget: under
/// parallel test load a wall-clock deadline says more about the machine than
/// about the scheduler.
@Suite("Sidebar index rebuilds are coalesced")
@MainActor
struct SidebarTaskIndexRebuildSchedulerTests {
    /// Yields until `condition` holds or the poll budget runs out. Returns
    /// whether it held, so a caller can assert on it rather than on elapsed
    /// time.
    private func waitUntil(_ condition: () -> Bool, polls: Int = 400) async -> Bool {
        for _ in 0..<polls {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test("The first change after a quiet stretch rebuilds without waiting")
    func firstChangeIsNotDelayed() async {
        let scheduler = SidebarTaskIndexRebuildScheduler(interval: 60)
        var rebuilds = 0
        scheduler.schedule { rebuilds += 1 }

        #expect(await waitUntil { rebuilds == 1 })
        #expect(!scheduler.hasPendingRebuildForTesting)
    }

    @Test("Changes arriving inside the window collapse into one rebuild")
    func burstsCollapse() async {
        let scheduler = SidebarTaskIndexRebuildScheduler(interval: 0.2)
        var rebuilds = 0
        // Stamps the window, the way every unscheduled rebuild does — first
        // appear, a search keystroke, a selection change. Without it the burst
        // below reads as the first change in a quiet stretch.
        scheduler.noteRebuilt()

        for _ in 0..<20 {
            scheduler.schedule { rebuilds += 1 }
        }
        #expect(scheduler.hasPendingRebuildForTesting)
        #expect(rebuilds == 0)

        #expect(await waitUntil { rebuilds > 0 })
        #expect(rebuilds == 1)
        #expect(!scheduler.hasPendingRebuildForTesting)
    }

    @Test("A rebuild scheduled after the window still runs")
    func windowReopens() async {
        let scheduler = SidebarTaskIndexRebuildScheduler(interval: 0.2)
        var rebuilds = 0
        scheduler.noteRebuilt()
        scheduler.schedule { rebuilds += 1 }
        #expect(await waitUntil { rebuilds == 1 })

        scheduler.noteRebuilt()
        scheduler.schedule { rebuilds += 1 }
        #expect(await waitUntil { rebuilds == 2 })
    }

    @Test("A sidebar leaving the hierarchy drops its pending rebuild")
    func cancelDropsPendingWork() async {
        let scheduler = SidebarTaskIndexRebuildScheduler(interval: 0.2)
        var rebuilds = 0
        scheduler.noteRebuilt()
        scheduler.schedule { rebuilds += 1 }
        #expect(scheduler.hasPendingRebuildForTesting)

        scheduler.cancel()
        #expect(!scheduler.hasPendingRebuildForTesting)
        // Long enough that the window would have elapsed several times over.
        _ = await waitUntil({ rebuilds > 0 }, polls: 60)
        #expect(rebuilds == 0)
    }
}
