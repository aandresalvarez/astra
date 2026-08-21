import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Establishes how wide SwiftData's `@Query` invalidation actually is, because
/// `SidebarTaskStore` is built on the answer.
///
/// The sidebar can no longer afford to fetch every `AgentTask` each time one of
/// them changes — measured at ~64 ms a fetch on a production-shaped store,
/// several times a second while a task streams. The fix is to let a cheap query
/// carry the *signal* that something changed and do the expensive fetch on a
/// coalesced schedule. That only works if a narrow query still re-runs `body`
/// when a row it does not match is mutated. If it doesn't, the sidebar would go
/// silently stale, which is worse than being slow.
///
/// `UsageDashboardSummaryMemo` already asserts this in prose ("re-runs `body` on
/// ANY mutation to a tracked `AgentTask`/`TaskRun`"). This pins it as a fact.
@Suite("SwiftData @Query invalidation breadth")
@MainActor
struct SwiftDataQueryInvalidationBreadthTests {
    private final class BodyCounter {
        var count = 0
    }

    /// The exact query shape `TaskSidebarContainerView` ships: one row, no
    /// predicate, no sort — the cheapest fetch that still subscribes the view
    /// to `AgentTask` invalidation.
    private struct NarrowQueryProbe: View {
        @Query(SidebarTaskFetch.invalidationSignalDescriptor())
        private var signal: [AgentTask]

        let counter: BodyCounter

        var body: some View {
            // Reading the query is what subscribes this view to it.
            let _ = signal.count
            counter.count += 1
            return Color.clear.frame(width: 10, height: 10)
        }
    }

    /// Hosts the probe behind a switch so the test can take it back out again
    /// when it is done with it, and stop it answering other suites' saves.
    private struct ProbeHost: View {
        let container: ModelContainer
        let counter: BodyCounter
        var showsProbe: Bool

        var body: some View {
            Group {
                if showsProbe {
                    NarrowQueryProbe(counter: counter)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)
            .modelContainer(container)
        }
    }

    /// Holds the probe's container, hosting view and window for the rest of the
    /// process. Nothing here may ever be released.
    ///
    /// A `@Query` registers an observer with the notification center, and in a
    /// test binary that registration is not reliably retired when the view
    /// declaring it goes away: hiding the view, clearing the window's content,
    /// ordering the window out and draining the runloop all leave it in place.
    /// A leaked observer is survivable on its own — it costs an extra `LIMIT 1`
    /// re-read when some other suite saves. What is *not* survivable is that
    /// observer outliving the `ModelContainer` it reads from. Then the next
    /// `context.save()` anywhere in the process posts to it, it reaches into a
    /// freed container, and SwiftData traps — taking the whole test binary down
    /// partway through an unrelated suite.
    ///
    /// That is not hypothetical. Six `swiftpm-testing-helper` crash reports say
    /// exactly this, every one of them
    /// `__CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__` into
    /// `_SwiftData_SwiftUI` beneath another suite's save — one of them 45
    /// minutes into a full run. Retaining the container is what makes the leak
    /// harmless; the teardown below is what keeps it quiet.
    @MainActor
    private enum ProbeLifetime {
        private static var retained: [Any] = []

        static func keepAlive(_ values: Any...) {
            retained.append(contentsOf: values)
        }
    }

    /// Drives the runloop until `predicate` holds or the budget runs out, so
    /// the test waits on the actual update rather than a fixed sleep.
    private func spinRunLoop(until predicate: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Gives SwiftUI the runloop turns it needs to finish tearing a graph down.
    private func drainRunLoop(for duration: TimeInterval = 0.2) {
        spinRunLoop(until: { false }, timeout: duration)
    }

    @Test("A query matching no rows still re-runs body when an unmatched row is mutated")
    func narrowQueryInvalidatesOnUnmatchedRowMutation() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = AgentTask(title: "unmatched", goal: "goal")
        context.insert(task)
        try context.save()

        let counter = BodyCounter()
        var root = ProbeHost(container: container, counter: counter, showsProbe: true)
        let host = NSHostingView(rootView: root)

        // A real window: SwiftUI drives appearance off one, and a windowless
        // hosting view renders when laid out but never settles into the update
        // cycle the query needs.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        // Before anything can go wrong, and never undone — see `ProbeLifetime`.
        ProbeLifetime.keepAlive(container, host, window)
        defer {
            // Best effort at quieting the probe so it stops re-rendering on
            // every other suite's save. Correctness does not rest on this
            // working: `ProbeLifetime` is what makes a surviving observer safe.
            // `orderOut` rather than `close`, because a closed window may
            // release itself and the whole point here is that it must not.
            root.showsProbe = false
            host.rootView = root
            drainRunLoop()
            host.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()

        spinRunLoop(until: { counter.count > 0 })
        let baseline = counter.count
        #expect(baseline > 0, "The probe never rendered; the rest of this test would be vacuous")

        // Mutate a row the query does not match, the way a streamed event does.
        task.updatedAt = Date().addingTimeInterval(60)
        try context.save()

        spinRunLoop(until: { counter.count > baseline })
        #expect(
            counter.count > baseline,
            """
            A narrow @Query did NOT re-run body when an unmatched row changed. \
            SidebarTaskStore's cheap-signal design depends on this; if this ever \
            fails, the sidebar must go back to observing an unfiltered query or \
            to an explicit change notification, or it will render stale.
            """
        )
    }
}
