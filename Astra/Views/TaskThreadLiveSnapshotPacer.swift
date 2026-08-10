import Foundation

/// Duty-cycle governor for live transcript updates.
///
/// The transcript pipeline shipped with a 120 ms floor
/// (`TaskThreadViewModel.liveSnapshotMinimumInterval`) that never once fired.
/// It compared `lastSnapshotApplyAt` against the moment a request reached the
/// throttle, and on the storage-backed path that moment is always at least the
/// view-mutation deferral plus the 120 ms refresh debounce plus a main-context
/// save plus a store read after the apply -- so `elapsed < 0.120` was
/// unsatisfiable at every thread size, and production logged
/// `throttle_delay_ms=0.00` / `deferred_snapshot_count=0` on every sample it
/// ever emitted. Worse, the interval it measured was apply -> request, so when
/// applies got slower the gap grew and the throttle *relaxed as load rose*.
///
/// A fixed interval could not have worked anyway. In the recorded hang -- 545
/// events, 149 conversation items, 50 runs, one running task -- the build cost
/// 369-390 ms and the SwiftUI layout pass the apply triggered cost ~700 ms
/// (`main_actor_max_stall_ms=703.63`). Nothing in the build path measures that
/// pass: `lastSnapshotApplyAt` is stamped when the `@Observable` property is
/// assigned, which is before SwiftUI flushes the transaction. `build_ms` read
/// 390 ms while the true per-update main-actor cost was nearly three times
/// that.
///
/// So this type does not pick an interval; it measures one. After each live
/// apply it asks how much main-actor time that apply consumed
/// (`TaskThreadMainActorStallSampler`'s control window) and holds the next
/// update until that cost is at most `maxMainActorDutyCycle` of the elapsed
/// period. A cheap thread measures ~0 ms, computes a target period of 0, adds
/// no delay, and falls through to the plain debounce -- today's behaviour
/// exactly. Only a thread whose renders are measurably expensive is slowed, and
/// only in proportion to how expensive they measurably are.
///
/// Attribution is the part that is easy to get wrong, and it is settled by a
/// scheduling fact rather than a heuristic: SwiftUI's layout pass for an
/// assignment runs synchronously inside a CFRunLoop observer on the main actor,
/// so *any* main-actor code that runs afterwards is proof the pass has
/// finished. Every decision here runs on the main actor. None of them has to
/// know when the render ended or which block was the render; each simply asks
/// how much main-actor time has elapsed since the last apply, and the answer
/// necessarily contains the whole render.
@MainActor
final class TaskThreadLiveSnapshotPacer {
    /// Ceiling on the share of the main actor that transcript updates may
    /// consume while a task streams. At the incident's ~700 ms render this
    /// yields a ~1.4 s admission period: still live, and it leaves the other
    /// half of the main actor for typing, scrolling and the composer, which had
    /// none at all. A diagnostic control target, not a product SLO
    /// (`docs/performance/files-shelf-validation.md:63-65` forbids inventing
    /// one) -- chosen as the largest value that still guarantees the user half
    /// the main thread.
    nonisolated static let maxMainActorDutyCycle: Double = 0.5
    /// The coalescing floor the pipeline already had. Returning exactly this is
    /// what "the pacer is inactive" means.
    nonisolated static let defaultBaseDebounceNanoseconds: UInt64 = 120_000_000
    /// Hard ceiling on the admission deadline, and the reason this loop cannot
    /// wedge. The target grows at 1/`maxMainActorDutyCycle` times the rate
    /// observed busy time grows, so on a main actor saturated by work the
    /// transcript did not cause the deadline would recede faster than wall time
    /// advances and no update would ever be admitted. Clamping to
    /// `lastApplyAt + 2 s` makes "an update is admitted" independent of the
    /// measurement: worst case the transcript refreshes at 0.5 Hz.
    nonisolated static let maximumPeriodNanoseconds: UInt64 = 2_000_000_000
    /// A residual under one frame is not worth another hop, and rounding it to
    /// zero is what stops the reconcile loop from re-arming for remainders it
    /// cannot deliver on anyway.
    nonisolated static let admissionQuantumNanoseconds: UInt64 = 8_000_000

    struct Decision: Equatable, Sendable {
        enum Reason: String, Sendable {
            /// No live apply has been observed, or the pacer was disarmed by a
            /// terminal apply or a task switch. The caller's floor is returned
            /// untouched.
            case unpaced
            /// Occupancy was measured but the deadline has already passed, so
            /// the caller's own debounce is the binding constraint.
            case debounce
            /// The measured duty cycle is holding this update back.
            case duty
            /// The deadline was clamped by `maximumPeriodNanoseconds`: the main
            /// actor is busier than transcript pacing alone can account for.
            case ceiling
        }

        let delayNanoseconds: UInt64
        let reason: Reason

        var delayMilliseconds: Double { Double(delayNanoseconds) / 1_000_000 }
    }

    private let baseDebounceNanoseconds: UInt64
    private let monotonicNow: @MainActor () -> ContinuousClock.Instant

    private var lastApplyAt: ContinuousClock.Instant?
    /// Main-actor time attributed to the apply at `lastApplyAt`. Accumulated
    /// rather than replaced: the sampler's control window is read-and-clear and
    /// is drained at every decision point, so the period total is only correct
    /// if each drained fragment is added here.
    private var busySinceApplyNanoseconds: UInt64 = 0
    private var targetPeriodNanoseconds: UInt64 = 0
    private var isArmed = false

    // Telemetry accumulators, deliberately separate from the control state
    // above for the same reason the sampler now keeps two windows: a skipped
    // cadence sample must not be able to change what the controller sees.
    private var heldRefreshCount = 0
    private var reconcileCount = 0
    private var insertedDelayNanoseconds: UInt64 = 0
    private var lastPeriodNanoseconds: UInt64 = 0
    private var lastPeriodBusyNanoseconds: UInt64 = 0
    private var lastReason: Decision.Reason = .unpaced

    init(
        baseDebounceNanoseconds: UInt64 = TaskThreadLiveSnapshotPacer.defaultBaseDebounceNanoseconds,
        monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = {
            ContinuousClock().now
        }
    ) {
        self.baseDebounceNanoseconds = baseDebounceNanoseconds
        self.monotonicNow = monotonicNow
    }

    /// True once a live apply has been observed. Used by the terminal drain to
    /// decide whether an in-flight pace interval needs cancelling, and used
    /// instead of `task.status` as the liveness test for admission: the apply
    /// site already computes the authoritative test (which includes
    /// `latestRunStatus == .running`, a case `task.status` alone misses), so
    /// carrying the answer forward is strictly better than recomputing a weaker
    /// one at the request site.
    var isPacing: Bool { isArmed }

    /// Folds one read of the sampler's control window into the current period.
    func observe(_ occupancy: TaskThreadMainActorStallSampler.Occupancy) {
        guard isArmed else { return }
        busySinceApplyNanoseconds &+= occupancy.busyNanoseconds
    }

    /// Delay for the first arm of a coalescing window. The debounce floor still
    /// applies: it exists to collapse a burst, which the duty cycle says
    /// nothing about.
    func armDelay() -> Decision {
        admissionDelay(minimumDelayNanoseconds: baseDebounceNanoseconds)
    }

    /// Delay for a re-arm from inside `performRequestedRefresh`. No floor: the
    /// burst this window exists to coalesce has already been waited out, so
    /// re-applying the debounce here would stack 120 ms onto every period. A
    /// return of zero means "admit now".
    func reconcileDelay() -> Decision {
        reconcileCount += 1
        return admissionDelay(minimumDelayNanoseconds: 0)
    }

    private func admissionDelay(minimumDelayNanoseconds: UInt64) -> Decision {
        guard isArmed, let lastApplyAt else {
            lastReason = .unpaced
            return Decision(delayNanoseconds: minimumDelayNanoseconds, reason: .unpaced)
        }
        let uncappedTarget = Double(busySinceApplyNanoseconds) / Self.maxMainActorDutyCycle
        let didClamp = uncappedTarget > Double(Self.maximumPeriodNanoseconds)
        targetPeriodNanoseconds = didClamp
            ? Self.maximumPeriodNanoseconds
            : UInt64(uncappedTarget)
        let elapsed = elapsedNanoseconds(since: lastApplyAt)
        let rawRemaining = targetPeriodNanoseconds > elapsed
            ? targetPeriodNanoseconds &- elapsed
            : 0
        let remaining = rawRemaining < Self.admissionQuantumNanoseconds ? 0 : rawRemaining
        if remaining > 0 {
            heldRefreshCount += 1
            insertedDelayNanoseconds &+= remaining
        }
        lastReason = remaining == 0 ? .debounce : (didClamp ? .ceiling : .duty)
        return Decision(
            delayNanoseconds: max(minimumDelayNanoseconds, remaining),
            reason: lastReason
        )
    }

    /// Closes the loop. Call immediately after the `@Observable` snapshot
    /// property has been assigned and before returning to the run loop: the
    /// layout pass this apply causes has not started yet, so everything the
    /// probe reports between here and the next decision belongs to it.
    ///
    /// A non-live apply disarms instead of measuring. Pacing exists to survive a
    /// stream; once the stream stops there is nothing to pace, and a paced
    /// terminal transcript is the "the transcript stopped updating" symptom
    /// these seams exist to prevent.
    func recordApply(isLive: Bool, synchronousApplyNanoseconds: UInt64) {
        let now = monotonicNow()
        if let lastApplyAt {
            lastPeriodNanoseconds = elapsedNanoseconds(since: lastApplyAt)
            lastPeriodBusyNanoseconds = busySinceApplyNanoseconds
        }
        guard isLive else {
            reset()
            return
        }
        isArmed = true
        lastApplyAt = now
        // Seeded with the synchronous half of the apply. The probe cannot see
        // it -- it is over before the probe's next wake, and under the control
        // window's noise floor anyway -- but it is real transcript cost, and
        // excluding it biases the duty cycle low on precisely the threads where
        // the apply body itself has stopped being free.
        busySinceApplyNanoseconds = synchronousApplyNanoseconds
    }

    /// Clears control state only. Telemetry accumulators survive so the sample
    /// that reports a period is not erased by the disarm that ends it; the view
    /// model's `reset(for:)` drains those separately on a task switch.
    func reset() {
        isArmed = false
        lastApplyAt = nil
        busySinceApplyNanoseconds = 0
        targetPeriodNanoseconds = 0
    }

    /// Read-and-clear, mirroring `TaskThreadMainActorStallSampler`, so each
    /// cadence sample reports only its own window.
    func consumeTelemetryFields() -> [String: String] {
        let dutyCycle = lastPeriodNanoseconds > 0
            ? Double(lastPeriodBusyNanoseconds) / Double(lastPeriodNanoseconds)
            : 0
        defer {
            heldRefreshCount = 0
            reconcileCount = 0
            insertedDelayNanoseconds = 0
        }
        return [
            // Retains the field name the existing dashboards and
            // `UIResponsivenessDiagnostics` summaries already key on; the source
            // moved from a throttle that never fired to one that does.
            "throttle_delay_ms": String(format: "%.2f", Double(insertedDelayNanoseconds) / 1_000_000),
            "deferred_snapshot_count": PerformanceTelemetryFields.count(heldRefreshCount),
            "pace_target_ms": String(format: "%.2f", Double(targetPeriodNanoseconds) / 1_000_000),
            "pace_render_ms": String(format: "%.2f", Double(lastPeriodBusyNanoseconds) / 1_000_000),
            "pace_period_ms": String(format: "%.2f", Double(lastPeriodNanoseconds) / 1_000_000),
            "pace_duty": String(format: "%.2f", dutyCycle),
            "pace_reconcile_count": PerformanceTelemetryFields.count(reconcileCount),
            "pace_state": lastReason.rawValue
        ]
    }

    private func elapsedNanoseconds(since instant: ContinuousClock.Instant) -> UInt64 {
        let components = instant.duration(to: monotonicNow()).components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        return UInt64(components.seconds) &* 1_000_000_000
            &+ UInt64(components.attoseconds) / 1_000_000_000
    }
}
