import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Covers the bargain `SidebarTaskStore` makes: skip the full read on the
/// invalidations that don't need one, and never let that skipping show.
///
/// The first half is the performance claim (a streaming task must not make the
/// sidebar re-read the table). The second half is the safety claim, and it is
/// the one worth being strict about — a store that is fast because it stopped
/// noticing inserts and deletes would be a worse bug than the lag it replaced.
@Suite("Sidebar task store")
@MainActor
struct SidebarTaskStoreTests {
    /// Short windows so the tests finish quickly; the ratios between them
    /// match the shipped defaults.
    private static let coalesce: TimeInterval = 0.02
    private static let membershipProbe: TimeInterval = 0.16

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func makeStore() -> SidebarTaskStore {
        SidebarTaskStore(
            coalesceInterval: Self.coalesce,
            membershipProbeInterval: Self.membershipProbe
        )
    }

    @discardableResult
    private func insertTask(_ title: String, into context: ModelContext) throws -> AgentTask {
        let task = AgentTask(title: title, goal: "goal for \(title)")
        context.insert(task)
        try context.save()
        return task
    }

    /// Floor on how many main-actor turns a wait must hand out before it is
    /// allowed to conclude that nothing happened.
    ///
    /// The full run puts 200-odd `@MainActor` suites on one actor, and one of
    /// them holding it for a second at a time is ordinary — the same runs show
    /// an unrelated test overshooting a *thirty* second budget. A wait that
    /// watched only the clock would come back from a stall having given the
    /// store no turns at all and report that as "the store never reconciled".
    /// Counting turns instead of seconds is what actually makes a slow machine
    /// wait longer rather than fail.
    private static let minimumPolls = 250

    /// Polls rather than sleeping a fixed amount, so a slow machine waits
    /// longer instead of failing.
    ///
    /// Both bounds have to be exhausted before this gives up: the deadline
    /// stops a genuinely stuck store from hanging the suite, and the poll floor
    /// stops a starved one from being mistaken for it. A satisfied predicate
    /// still returns on the next turn, so neither bound slows the happy path.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 10.0,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        while !predicate(), polls < Self.minimumPolls || Date() < deadline {
            polls += 1
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return predicate()
    }

    /// Lets every scheduled reconcile run to completion, including the
    /// membership probe, so "nothing happened" assertions are not just early
    /// reads.
    ///
    /// Counts turns as well as seconds, for the reason given on
    /// `minimumPolls`: a fixed sleep that elapsed inside someone else's
    /// main-actor stall proves nothing about what this store did or did not do,
    /// and every assertion downstream of it would be vacuous.
    private func settle() async {
        let deadline = Date().addingTimeInterval(Self.membershipProbe * 3)
        var polls = 0
        while polls < Self.minimumPolls || Date() < deadline {
            polls += 1
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test("The first load fills the sidebar and does not repeat")
    func initialLoadPopulatesOnce() throws {
        let context = try makeContext()
        try insertTask("First", into: context)
        try insertTask("Second", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        #expect(store.tasks.count == 2)
        #expect(store.fetchCountForTesting == 1)

        store.loadIfNeeded(context: context)
        #expect(store.fetchCountForTesting == 1, "loadIfNeeded must be idempotent")
    }

    /// The whole point of the type. `AgentEventRecorder` writes `updatedAt`,
    /// `tokensUsed`, and `costUSD` for every streamed event, and each of those
    /// used to cost the sidebar a full table read.
    @Test("A streaming task's field writes never trigger a re-read")
    func fieldMutationsDoNotRefetch() async throws {
        let context = try makeContext()
        let task = try insertTask("Streaming", into: context)
        for index in 0..<20 {
            try insertTask("Other \(index)", into: context)
        }

        let store = makeStore()
        store.loadIfNeeded(context: context)
        let afterLoad = store.fetchCountForTesting
        let versionAtLoad = store.tasksVersion

        // Spread across its own coalescing window each, so this measures the
        // membership check and not the window. A tight synchronous loop would
        // collapse into one reconcile no matter what the store did next, and
        // would pass even with the check removed.
        let batches = 12
        for index in 0..<batches {
            task.updatedAt = Date().addingTimeInterval(Double(index))
            task.tokensUsed += 10
            task.costUSD += 0.001
            store.noteChanged(context: context)
            try? await Task.sleep(nanoseconds: UInt64(Self.coalesce * 2 * 1_000_000_000))
        }
        await settle()

        // Exactly zero, not "bounded by elapsed time": the timed full re-read
        // this used to allow for ran 117 times in 2.7 days of production and
        // found a change on none of them, at 571 ms of blocked main thread
        // apiece. Membership did not move here, so nothing may be read.
        #expect(
            store.fetchCountForTesting == afterLoad,
            """
            \(batches) field writes caused \(store.fetchCountForTesting - afterLoad) full \
            reads. Field changes reach the view through @Observable on the model objects \
            the snapshot already holds, and through `tasksVersion`; re-reading the table \
            for them is the lag this store exists to remove.
            """
        )
        #expect(store.tasks.count == 21)
        // Skipping the read must not mean skipping the *signal*. The sidebar
        // index is rebuilt off `tasksVersion`, so a store that went quiet here
        // would be fast and wrong.
        #expect(
            store.tasksVersion != versionAtLoad,
            "Field writes never reached tasksVersion, so the sidebar index would never rebuild"
        )
    }

    @Test("A burst of change signals collapses into a single reconcile")
    func signalBurstCoalesces() async throws {
        let context = try makeContext()
        try insertTask("Only", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        let afterLoad = store.fetchCountForTesting

        // Insert once, then signal many times inside one window. The insert
        // must be picked up, but only once.
        try insertTask("Appeared", into: context)
        for _ in 0..<50 {
            store.noteChanged(context: context)
        }

        #expect(await waitUntil { store.tasks.count == 2 })
        #expect(
            store.fetchCountForTesting - afterLoad == 1,
            "50 signals in one window should buy exactly one read, not \(store.fetchCountForTesting - afterLoad)"
        )
    }

    @Test("An inserted task appears without being announced")
    func insertIsPickedUp() async throws {
        let context = try makeContext()
        try insertTask("Existing", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)

        try insertTask("New", into: context)
        store.noteChanged(context: context)

        #expect(await waitUntil { store.tasks.map(\.title).sorted() == ["Existing", "New"] })
    }

    /// A deleted model is unsafe to read from, so this can never be deferred
    /// to the backstop — it is the one condition checked before anything else.
    @Test("A deleted task is dropped and never left in the snapshot")
    func deleteIsPickedUp() async throws {
        let context = try makeContext()
        let doomed = try insertTask("Doomed", into: context)
        try insertTask("Survivor", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        #expect(store.tasks.count == 2)

        context.delete(doomed)
        try context.save()
        store.noteChanged(context: context)

        #expect(await waitUntil { store.tasks.map(\.title) == ["Survivor"] })
        #expect(!store.tasks.contains { $0.isDeleted })
    }

    @Test("refreshNow picks up a change without waiting out the window")
    func refreshNowSkipsTheWindow() throws {
        let context = try makeContext()
        try insertTask("Existing", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)

        try insertTask("New", into: context)
        store.refreshNow(context: context)

        // Synchronous: no polling, no sleep.
        #expect(store.tasks.count == 2)
    }

    /// `refreshNow` runs the same tests as the coalesced path, so a handler
    /// that opened a confirmation sheet instead of deleting anything must not
    /// cost a full read.
    @Test("refreshNow after a no-op action does not re-read")
    func refreshNowAfterNoChangeIsFree() throws {
        let context = try makeContext()
        try insertTask("Existing", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        let afterLoad = store.fetchCountForTesting

        store.refreshNow(context: context)
        #expect(store.fetchCountForTesting == afterLoad)
    }

    /// The safety net for what the two cheap tests cannot see: one row deleted
    /// and another inserted between reconciles leaves the count unchanged and
    /// nothing in the snapshot marked deleted, so the store would show a task
    /// that no longer exists and hide one that does.
    ///
    /// This used to be a full re-read on a timer, and production settled the
    /// question: 117 firings over 2.7 days, 67.3 seconds of blocked main
    /// thread, and not one membership change found. So the schedule now carries
    /// an identifier-only probe, and the read is reserved for the case where
    /// the probe actually disagrees.
    @Test("The membership probe runs on schedule and costs no reads while membership holds")
    func membershipProbeRunsOnScheduleWithoutReading() async throws {
        let context = try makeContext()
        try insertTask("Stable", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        let afterLoad = store.fetchCountForTesting
        let probesAfterLoad = store.membershipProbeCountForTesting

        // Nothing changes for the whole run: no inserts, no deletes.
        //
        // Two exit conditions, and both have to be met. The span is what the
        // rate is measured over; the poll floor is what guarantees the store
        // was actually given turns to fire in. Wall clock alone would let a
        // stall consume the whole span and return having run nothing, which
        // reads identically to a schedule that never fires.
        let intervals = 4.0
        let started = Date()
        var polls = 0
        while Date().timeIntervalSince(started) < Self.membershipProbe * intervals
            || (polls < Self.minimumPolls
                && store.membershipProbeCountForTesting == probesAfterLoad) {
            polls += 1
            store.noteChanged(context: context)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let elapsed = Date().timeIntervalSince(started)
        let probes = store.membershipProbeCountForTesting - probesAfterLoad

        #expect(
            probes >= 1,
            """
            The probe never ran over \(elapsed)s of continuous signals. Without it, a \
            delete-plus-insert inside one window leaves the sidebar showing a task that no \
            longer exists.
            """
        )
        // Bounded by the span actually observed, not the one asked for: if the
        // loop was held off and ran long, more probes are correct, and checking
        // against the intended span would call the schedule broken for it.
        let permitted = elapsed / Self.membershipProbe + 1
        #expect(
            Double(probes) <= permitted,
            """
            \(probes) probes over \(elapsed)s allows at most \(permitted) — the schedule is \
            not bounding the rate
            """
        )
        #expect(
            store.fetchCountForTesting == afterLoad,
            """
            The probe pulled \(store.fetchCountForTesting - afterLoad) full reads behind it \
            without membership having changed. Reading on the schedule instead of on the \
            finding is the regression this replaced.
            """
        )
    }

    /// The case the probe exists for: as many rows as before, but not the same
    /// rows, and nothing in the snapshot marked deleted to give it away.
    ///
    /// The real interleaving — one row deleted and another inserted between
    /// reconciles — cannot be staged in-process, because within a single
    /// context any row the snapshot holds that the store no longer returns is
    /// by definition `isDeleted`, and the first check catches it. So the
    /// snapshot is corrupted directly instead, with a live row belonging to a
    /// *different* store: same count, no deleted objects, one identity the
    /// probe has never seen. That is the state the real interleaving produces,
    /// reached by the only route a test has to it.
    @Test("A count-preserving swap is caught by the identifier probe")
    func countPreservingSwapIsDetected() async throws {
        let context = try makeContext()
        try insertTask("Alpha", into: context)
        try insertTask("Beta", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        #expect(store.tasks.count == 2)

        let elsewhere = try makeContext()
        let foreign = try insertTask("Not in this store", into: elsewhere)
        store.replaceSnapshotForTesting([store.tasks[0], foreign])

        // `fetchCount` still says 2, and neither held row is deleted, so both
        // cheap checks pass. Only the identity comparison can disagree.
        #expect(await waitUntil {
            store.noteChanged(context: context)
            return store.tasks.map(\.title).sorted() == ["Alpha", "Beta"]
        })
        #expect(store.membershipProbeCountForTesting >= 1)
    }

    /// The app can swap the active store — a recovery store replacing the
    /// default one — underneath a live sidebar. Neither cheap test would catch
    /// that if the two stores happened to hold the same number of tasks, so the
    /// swap itself has to force a read.
    @Test("Swapping the model context re-reads immediately")
    func contextSwapForcesAReRead() throws {
        let first = try makeContext()
        try insertTask("From first store", into: first)

        let store = makeStore()
        store.loadIfNeeded(context: first)
        #expect(store.tasks.map(\.title) == ["From first store"])

        // Same task count, entirely different rows.
        let second = try makeContext()
        try insertTask("From second store", into: second)
        store.noteChanged(context: second)

        #expect(store.tasks.map(\.title) == ["From second store"])
    }

    /// If a reconcile that found nothing republished the snapshot, it would
    /// re-run the view body, which calls `noteChanged`, which schedules
    /// another reconcile — a 4 Hz spin that never settles.
    @Test("A reconcile that finds nothing leaves the snapshot alone")
    func unchangedReconcileDoesNotRepublish() async throws {
        let context = try makeContext()
        try insertTask("Stable", into: context)

        let store = makeStore()
        store.loadIfNeeded(context: context)
        let held = store.tasks
        let probesAfterLoad = store.membershipProbeCountForTesting

        // Signal until the probe actually runs: suppression can only be
        // demonstrated against a check that really happened.
        let sawProbe = await waitUntil {
            store.noteChanged(context: context)
            return store.membershipProbeCountForTesting > probesAfterLoad
        }
        #expect(sawProbe, "No probe ran; the suppression check below would be vacuous")
        #expect(store.tasks.count == held.count)
        for (before, after) in zip(held, store.tasks) {
            #expect(before === after, "The snapshot was replaced with equivalent contents")
        }
    }
}
