import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Exercises the same store lifecycle as the sidebar in a real hosted view.
/// Modern systems use source observers; Sonoma retains its bounded Query
/// signal. Tests never call `noteChanged` themselves.
@Suite("Sidebar task store signal integration")
@MainActor
struct SidebarTaskStoreSignalIntegrationTests {
    @MainActor
    private final class WeakProbe {
        weak var container: ModelContainer?
        weak var host: AnyObject?
        weak var window: NSWindow?
        weak var store: SidebarTaskStore?

        init(container: ModelContainer, host: AnyObject, window: NSWindow, store: SidebarTaskStore) {
            self.container = container
            self.host = host
            self.window = window
            self.store = store
        }
    }

    /// Query observers on Sonoma and SwiftData's autosave timers on newer
    /// systems can outlive a hosted view in a test binary. Keep the fixture
    /// alive for later run-loop callbacks and other suites' save notifications.
    @MainActor
    private final class ProbeLifetime {
        static let process = ProbeLifetime()
        private var retained: [AnyObject] = []

        func keepAlive(_ objects: AnyObject...) {
            retained.append(contentsOf: objects)
        }
    }

    @Test("Hosted fixtures outlive their scope and are released with their lifetime owner")
    func fixtureLifetime() {
        final class Fixture {}
        weak var fixture: Fixture?
        do {
            let lifetime = ProbeLifetime()
            do {
                let object = Fixture()
                fixture = object
                lifetime.keepAlive(object)
            }
            withExtendedLifetime(lifetime) { #expect(fixture != nil) }
        }
        #expect(fixture == nil)
    }

    private final class BodyCounter {
        var count = 0
    }

    /// The container view's body, reduced to the parts that carry the signal.
    private struct SidebarSignalProbe: View {
        @Environment(\.modelContext) private var modelContext

        let store: SidebarTaskStore
        let counter: BodyCounter

        var body: some View {
            counter.count += 1
            return Color.clear
                .frame(width: 10, height: 10)
                .onAppear { store.loadIfNeeded(context: modelContext) }
                .background { SidebarTaskLegacyChangeSignal(store: store) }
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
            _ = await MainActor.run {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("A task created while the sidebar is on screen reaches the snapshot")
    func insertedTaskReachesTheSnapshot() async throws {
        let probe = try await exerciseHostedProbe()
        let other = try ModelContainer(for: ASTRASchema.current,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(other)
        context.insert(AgentTask(title: "After teardown", goal: "unrelated save"))
        try context.save()
        drainRunLoop()
        // Framework callbacks can arrive after view teardown. The fixture,
        // including its context/container, must still be alive at that point.
        #expect(probe.container != nil)
        #expect(probe.host != nil)
        #expect(probe.window != nil)
        #expect(probe.store != nil)
    }

    private func exerciseHostedProbe() async throws -> WeakProbe {
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
        ProbeLifetime.process.keepAlive(container, host, window, store)
        window.orderFront(nil)
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
        return WeakProbe(container: container, host: host, window: window, store: store)
    }
}
