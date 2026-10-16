import Foundation
import SwiftData
import ASTRAModels

/// Owns the sidebar's `AgentTask` snapshot so the view stops refetching the
/// whole table on every streamed token.
///
/// **The problem this replaces.** `TaskSidebarContainerView` held an unfiltered
/// `@Query`. On earlier SwiftData versions, query invalidation included writes outside
/// the result window,
/// and `AgentEventRecorder` writes `updatedAt` / `tokensUsed` / `costUSD` on the
/// streaming task for every event it records. So each token re-ran the
/// container's body, and each body eval re-read all 726 rows — measured at
/// ~64 ms against a production-shaped store, synchronously, on the main thread,
/// inside the SwiftUI view transaction. That is the stall the composer was
/// waiting on.
///
/// **Why the fetch can be skipped.** Almost every one of those invalidations is
/// a *field* change on a task the sidebar already holds. Field changes need no
/// refetch: `AgentTask` is `@Observable`, so a view that reads `task.status`
/// re-renders when it changes, through the object reference the snapshot
/// already has. Only a change in *membership* — a task inserted or deleted —
/// makes the snapshot itself wrong. So this store re-reads on membership
/// changes and lets everything else ride model observation, which is how the
/// rows updated anyway.
///
/// **How membership is detected**, cheapest test first:
/// 1. Any held row now `isDeleted`. Reading properties off a deleted model is
///    unsafe, so this can never wait for a later pass.
/// 2. `fetchCount` disagrees with the snapshot. Measured at **0.03 ms against
///    65.78 ms** for the read it guards on a production-shaped store — a
///    factor of ~1,950, so this check is free at any rate the UI can generate
///    (`SidebarTaskFetchBenchmarkTests.fetchCountIsCheaperThanFetch`).
/// 3. Failing both, an identifier-only read at most once per
///    `membershipProbeInterval`, compared against the rows already held. This
///    covers the count-preserving change — one row deleted and another inserted
///    inside the same window — that the first two tests miss.
///
/// Test 3 used to be a *full* re-read on that same schedule, and production
/// disproved it: over 2.7 days it ran 117 times, cost 67.3 seconds of blocked
/// main thread (mean 571 ms, worst 995 ms), and **never once** found a change —
/// tests 1 and 2 fired zero times between them. A periodic full read is the
/// wrong price for a case this rare. `fetchIdentifiers` answers the same
/// question without materialising a single object, so the expensive read now
/// happens only when membership has actually moved.
///
/// Save notifications signal membership changes. Observation of the held
/// models' index fields also signals unsaved writes, including streamed events.
/// Neither depends on SwiftUI invalidating an unchanged query result set.
/// Outside the actor so they can be default arguments; see `SidebarTaskStore`.
enum SidebarTaskStoreDefaults {
    /// Trailing window on the invalidation signal. Long enough that a burst of
    /// streamed tokens collapses into one check, short enough that a task
    /// appearing or disappearing still reads as immediate.
    ///
    /// It is a *trailing* window only while signals keep arriving. The first
    /// signal after a quiet stretch reconciles on the next main-actor turn, so
    /// a pin or a mark-done from an idle sidebar regroups within a frame
    /// instead of waiting out a window it did not need.
    static let coalesceInterval: TimeInterval = 0.25
    /// Upper bound on how long a count-preserving membership change can go
    /// unseen. Bounds the identifier probe, not a full read.
    static let membershipProbeInterval: TimeInterval = 2.0
}

@MainActor
@Observable
final class SidebarTaskStore {
    /// The sidebar's snapshot. Replaced only when membership actually changed,
    /// because assigning it unnecessarily re-runs the view body.
    private(set) var tasks: [AgentTask] = []

    /// Fingerprint of the snapshot's index-relevant fields, for the view to
    /// hang its index rebuild on.
    ///
    /// This lives here rather than in the view because computing it reads a
    /// handful of fields off every task, and doing that inside `body` makes the
    /// view observe all of them: a single streamed token then re-runs the
    /// sidebar body, which recomputes the fingerprint, which is what made it
    /// cost 3.4% of wall clock. Computed here it runs at the reconcile rate,
    /// off the view-update path, and the view observes one `Int`.
    private(set) var tasksVersion = 0

    // Scheduling and source subscriptions are not presentation state.
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var changes: SidebarTaskChangeObservation?
    @ObservationIgnored private var probeAfterSave = false
    @ObservationIgnored private var externalUpdates: Set<PersistentIdentifier> = []
    @ObservationIgnored private var pendingReconcile: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var lastReconcileAt = Date.distantPast
    @ObservationIgnored private var lastMembershipProbeAt = Date.distantPast
    @ObservationIgnored private let coalesceInterval: TimeInterval
    @ObservationIgnored private let membershipProbeInterval: TimeInterval

    /// How many full reads this store has performed. The point of the type is
    /// that this stays near-flat while a task streams, which is not observable
    /// from `tasks` alone — a skipped read and a read that changed nothing look
    /// identical from outside. Nothing in the app reads it.
    @ObservationIgnored private(set) var fetchCountForTesting = 0

    /// How many identifier probes have run. Separated from `fetchCountForTesting`
    /// because the whole point of the probe is that it is *not* a read: a test
    /// that could not tell them apart would pass on the regression this
    /// replaced.
    @ObservationIgnored private(set) var membershipProbeCountForTesting = 0

    init(
        coalesceInterval: TimeInterval = SidebarTaskStoreDefaults.coalesceInterval,
        membershipProbeInterval: TimeInterval = SidebarTaskStoreDefaults.membershipProbeInterval
    ) {
        self.coalesceInterval = coalesceInterval
        self.membershipProbeInterval = membershipProbeInterval
    }

    /// First read, on appear. Synchronous so the sidebar never renders an empty
    /// rail it then has to fill in.
    func loadIfNeeded(context: ModelContext) {
        guard !hasLoaded else { return }
        hasLoaded = true
        bind(context)
        fetch(reason: "initial")
    }

    /// Called by source observation. Coalesces saves and unsaved field writes
    /// without forcing the sidebar to fetch or render on every event.
    func noteChanged(
        context: ModelContext, membershipMayHaveChanged: Bool = false,
        externallyUpdated: [PersistentIdentifier] = []
    ) {
        // A different context means a different store — the app can swap in a
        // recovery store underneath a live view. The snapshot then belongs to
        // something that is no longer being displayed, and no count or
        // isDeleted test would notice if the two happened to line up.
        if let existing = self.context, existing !== context {
            bind(context)
            pendingReconcile?.cancel()
            pendingReconcile = nil
            fetch(reason: "context_changed")
            return
        }
        if self.context == nil { bind(context) }
        probeAfterSave = probeAfterSave || membershipMayHaveChanged
        externalUpdates.formUnion(externallyUpdated)
        guard hasLoaded, pendingReconcile == nil else { return }
        // A signal arriving after a quiet stretch is a user action, not a
        // stream: pin, mark done, rename. Those regroup the rail, so making
        // them wait out a window built for token bursts reads as lag. The Task
        // still defers past the current view update — this must never write
        // observed state from inside the body that called it — so the "no
        // wait" path is one main-actor turn, not zero.
        let sinceLastReconcile = Date().timeIntervalSince(lastReconcileAt)
        pendingReconcile = Task { [weak self] in
            guard let self else { return }
            if sinceLastReconcile < self.coalesceInterval {
                try? await Task.sleep(nanoseconds: UInt64(self.coalesceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            self.pendingReconcile = nil
            self.reconcile()
        }
    }

    /// Skips the coalescing window, for a mutation the user just performed —
    /// deleting a task, deleting a workspace — where a row lingering for a
    /// third of a second reads as the app ignoring the click.
    ///
    /// It runs the same tests as the coalesced path, so calling it after an
    /// action that turned out to change nothing (a delete that opened a
    /// confirmation sheet instead) costs a `COUNT(*)`, not a full read.
    func refreshNow(context: ModelContext) {
        guard hasLoaded else {
            loadIfNeeded(context: context)
            return
        }
        if self.context !== context {
            bind(context)
            pendingReconcile?.cancel()
            pendingReconcile = nil
            fetch(reason: "context_changed")
            return
        }
        pendingReconcile?.cancel()
        pendingReconcile = nil
        reconcile()
    }

    /// Decides whether the expensive read is warranted, then does it.
    private func reconcile() {
        guard let context else { return }
        let forceProbe = probeAfterSave
        probeAfterSave = false
        refreshExternallyUpdatedRows(in: context)
        lastReconcileAt = Date()
        if tasks.contains(where: \.isDeleted) {
            fetch(reason: "deleted_row")
            return
        }
        if let count = try? context.fetchCount(SidebarTaskFetch.descriptor()), count != tasks.count {
            fetch(reason: "count_changed")
            return
        }

        // A save from another context can replace a row without marking this
        // context's held instance deleted. Check IDs before reading its fields.
        if forceProbe {
            lastMembershipProbeAt = Date()
            if membershipChanged(in: context) {
                fetch(reason: "saved_membership_changed")
                return
            }
        }

        // Membership is intact, but fields on the held rows may not be — a
        // status landing, an unread badge clearing. That is what the sidebar
        // index is keyed on, so it is republished on every reconcile, whether
        // or not the probe below runs.
        republishVersion()

        guard !forceProbe, Date().timeIntervalSince(lastMembershipProbeAt) >= membershipProbeInterval else { return }
        lastMembershipProbeAt = Date()
        guard membershipChanged(in: context) else { return }
        fetch(reason: "membership_changed")
    }

    /// The count-preserving case: as many rows as before, but not the same
    /// ones. Reads primary keys only — no objects materialised, no `goal` text
    /// off disk, no relationship faults — so the schedule that used to cost a
    /// 726-row read now costs a key scan.
    ///
    /// A read failure returns `false` rather than forcing a fetch. "Unreadable"
    /// is not "changed", and re-reading the whole table on every probe while a
    /// store is broken would reinstate exactly the stall this replaced.
    private func membershipChanged(in context: ModelContext) -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        membershipProbeCountForTesting += 1
        guard let identifiers = try? context.fetchIdentifiers(SidebarTaskFetch.descriptor()) else {
            PerformanceTelemetry.log(
                "sidebar_membership_probe_failed",
                level: .warning,
                fields: ["held_count": PerformanceTelemetryFields.count(tasks.count)]
            )
            return false
        }

        let held = Set(tasks.map(\.persistentModelID))
        // Identifiers are unique, so equal counts plus full containment is set
        // equality — one hash set instead of two.
        let changed = identifiers.count != held.count || !identifiers.allSatisfy(held.contains)
        PerformanceTelemetry.logIfNeeded(
            "sidebar_membership_probe",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_count": PerformanceTelemetryFields.count(identifiers.count),
                "changed": PerformanceTelemetryFields.bool(changed)
            ]
        )
        return changed
    }

    /// Recomputes the index fingerprint and publishes it only when it moved.
    ///
    /// `@Observable` notifies on assignment regardless of equality. Suppress
    /// unchanged versions so a save that changed nothing does not rebuild UI.
    private func republishVersion() {
        let version = changes?.track { SidebarTaskIndexInvalidation.signature(for: tasks) }
            ?? SidebarTaskIndexInvalidation.signature(for: tasks)
        guard version != tasksVersion else { return }
        tasksVersion = version
    }

    private func bind(_ context: ModelContext) {
        self.context = context
        probeAfterSave = false
        externalUpdates.removeAll()
        changes = SidebarTaskChangeObservation(context: context) { [weak self, weak context] membershipChanged, updated in
            guard let self, let context, self.context === context else { return }
            self.noteChanged(context: context, membershipMayHaveChanged: membershipChanged, externallyUpdated: updated)
        }
    }

    /// A manual snapshot needs an explicit refetch for writes from another
    /// context. Read just those rows; local streams never enter this path, and
    /// pending inserts/deletes remain owned by the UI context's normal fetch.
    private func refreshExternallyUpdatedRows(in context: ModelContext) {
        guard !externalUpdates.isEmpty else { return }
        // A committed refetch overwrites pending properties in SwiftData.
        // Defer dirty rows until their owner's next save; never discard edits
        // or implicitly save domain state merely to refresh presentation.
        let pending = context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray
        let pendingIDs = Set(pending.map(\.persistentModelID))
        let identifiers = Array(externalUpdates.subtracting(pendingIDs))
        guard !identifiers.isEmpty else { return }
        externalUpdates.subtract(identifiers)
        var descriptor = FetchDescriptor<AgentTask>(
            predicate: #Predicate { identifiers.contains($0.persistentModelID) }
        )
        descriptor.includePendingChanges = false
        do {
            _ = try context.fetch(descriptor)
        } catch {
            PerformanceTelemetry.log("sidebar_external_refresh_failed", level: .warning)
        }
    }

    private func fetch(reason: String) {
        guard let context else { return }
        probeAfterSave = false
        // A read is the strongest membership check there is, so it resets both
        // schedules — including the one taken by `loadIfNeeded`, which reaches
        // `fetch` without going through `reconcile`.
        lastReconcileAt = Date()
        lastMembershipProbeAt = Date()
        fetchCountForTesting += 1

        let fetched = PerformanceTelemetry.measure(
            "sidebar_task_fetch",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: ["reason": reason],
            resultFields: { result in
                ["task_count": PerformanceTelemetryFields.count(result?.count ?? -1)]
            }
        ) {
            try? context.fetch(SidebarTaskFetch.descriptor())
        }

        // A failed read must not blank the rail. Keeping the previous snapshot
        // is stale; publishing `[]` would look like every task was deleted.
        guard let fetched else {
            PerformanceTelemetry.log(
                "sidebar_task_fetch_failed",
                level: .warning,
                fields: ["reason": reason, "held_count": PerformanceTelemetryFields.count(tasks.count)]
            )
            return
        }

        if !holdsSameTasks(as: fetched) {
            tasks = fetched
        }
        // Unconditional: a read that returned the same rows can still have
        // returned different *fields* on them, and the index is keyed on those.
        republishVersion()
    }

    /// Corrupts the snapshot on purpose, so the identifier probe can be tested
    /// against the state it exists for.
    ///
    /// A count-preserving membership change cannot be staged through the public
    /// surface: within one context, any row the snapshot holds that the store
    /// no longer returns is `isDeleted`, and the first check catches it before
    /// the probe is reached. Nothing in the app calls this.
    func replaceSnapshotForTesting(_ snapshot: [AgentTask]) {
        tasks = snapshot
    }

    /// Pointer identity, not field equality: SwiftData uniques a model to one
    /// instance per context, so the same rows come back as the same objects and
    /// any field change is already visible through them. This asks only whether
    /// the *set* changed. A false negative costs one redundant publish, never a
    /// stale rail.
    private func holdsSameTasks(as fetched: [AgentTask]) -> Bool {
        guard tasks.count == fetched.count else { return false }
        for (held, incoming) in zip(tasks, fetched) where held !== incoming {
            return false
        }
        return true
    }
}
