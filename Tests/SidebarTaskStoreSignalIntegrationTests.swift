import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Wires the sidebar's snapshot the way `TaskSidebarContainerView` wires it —
/// a one-row `@Query` for the signal, `SidebarTaskStore` for the read — and
/// asks the only question that matters: does a task created while the sidebar
/// is on screen reach the rail?
///
/// `SidebarTaskStoreTests` calls `noteChanged` by hand, so it proves what the
/// store does *given* a signal. This proves the signal arrives at all, through
/// a real hosted view and a real container.
@Suite("Sidebar task store signal integration")
@MainActor
struct SidebarTaskStoreSignalIntegrationTests {
    private final class BodyCounter {
        var count = 0
    }

    /// The container view's body, reduced to the parts that carry the signal.
    private struct SidebarSignalProbe: View {
        @Query(SidebarTaskFetch.invalidationSignalDescriptor())
        private var taskChangeSignal: [AgentTask]
        @Environment(\.modelContext) private var modelContext

        let store: SidebarTaskStore
        let counter: BodyCounter

        var body: some View {
            let _ = taskChangeSignal.count
            store.noteChanged(context: modelContext)
            counter.count += 1
            return Color.clear
                .frame(width: 10, height: 10)
                .onAppear { store.loadIfNeeded(context: modelContext) }
        }
    }

    private struct ProbeHost: View {
        let container: ModelContainer
        let store: SidebarTaskStore
        let counter: BodyCounter
        var showsProbe: Bool

        var body: some View {
            Group {
                if showsProbe {
                    SidebarSignalProbe(store: store, counter: counter)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)
            .modelContainer(container)
        }
    }

    /// Retains the probe's container, host and window for the life of the
    /// process. A `@Query`'s notification observer outlives the view that
    /// declared it in a test binary, and one that outlives its `ModelContainer`
    /// traps inside an unrelated suite's save. See
    /// `SwiftDataQueryInvalidationBreadthTests.ProbeLifetime`.
    @MainActor
    private enum ProbeLifetime {
        private static var retained: [Any] = []

        static func keepAlive(_ values: Any...) {
            retained.append(contentsOf: values)
        }
    }

    /// Teardown only: lets the hosting view's pending updates run before the
    /// window goes away. A wall-clock bound is right here — nothing is being
    /// waited *for*, so a busy machine should spend less time draining, not
    /// more.
    private func drainRunLoop(for duration: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }

    /// Hands out both kinds of turn the sidebar needs: run-loop turns, which
    /// are what drive a hosted SwiftUI update, and main-actor turns, which are
    /// what run the store's scheduled reconcile. Spinning only the run loop
    /// starves the cooperative executor and makes a working store look stuck.
    ///
    /// Bounded by turns taken, never by wall clock. Under the full suite this
    /// thread is contended enough that a several-second deadline can expire
    /// after a handful of turns — which fails a store that is working, for
    /// being slow, on a machine that was busy.
    private func settle(until predicate: () -> Bool, turns: Int = 600) async {
        for _ in 0..<turns {
            if predicate() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("A task created while the sidebar is on screen reaches the snapshot")
    func insertedTaskReachesTheSnapshot() async throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "PCORnet Old Queries", primaryPath: "/tmp/pcornet")
        context.insert(workspace)
        context.insert(AgentTask(title: "seed", goal: "already on the rail"))
        try context.save()

        let store = SidebarTaskStore()
        let counter = BodyCounter()
        var root = ProbeHost(container: container, store: store, counter: counter, showsProbe: true)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        ProbeLifetime.keepAlive(container, host, window, store)
        defer {
            root.showsProbe = false
            host.rootView = root
            drainRunLoop()
            host.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()

        await settle(until: { store.tasks.count == 1 })
        #expect(store.tasks.count == 1, "The sidebar never loaded; the rest of this test would be vacuous")

        // What the app does when the user sends the first message in a new
        // workspace: a task, filed under that workspace, saved.
        let arrival = AgentTask(title: "hy what can you do ?", goal: "first task")
        arrival.workspace = workspace
        context.insert(arrival)
        try context.save()

        await settle(until: { store.tasks.count == 2 })
        #expect(
            store.tasks.contains { $0.id == arrival.id },
            """
            A task created with the sidebar on screen never reached the \
            snapshot. The rail shows whatever it loaded on appear, so new work \
            is invisible until relaunch.
            """
        )
        #expect(
            store.tasks.first { $0.id == arrival.id }?.workspace?.id == workspace.id,
            "The snapshot holds the task but not its workspace, so no drawer can list it."
        )
    }
}
