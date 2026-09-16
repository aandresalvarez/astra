import Foundation
import Testing
@testable import ASTRA

/// A hand-advanced monotonic clock. The pacer's whole contract is "how much
/// wall time has passed since the last apply", so driving it from real time
/// would make every assertion a race against the test host's own main-actor
/// contention -- the exact confound the production bug hid behind.
@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock().now

    func advance(milliseconds: Int) {
        now = now.advanced(by: .milliseconds(milliseconds))
    }
}

private func occupancy(milliseconds: Int) -> TaskThreadMainActorStallSampler.Occupancy {
    TaskThreadMainActorStallSampler.Occupancy(
        busyNanoseconds: UInt64(milliseconds) * 1_000_000,
        longestBlockNanoseconds: UInt64(milliseconds) * 1_000_000
    )
}

@Suite("Task thread live snapshot pacer")
@MainActor
struct TaskThreadLiveSnapshotPacerTests {
    private func makePacer(_ clock: ManualClock) -> TaskThreadLiveSnapshotPacer {
        TaskThreadLiveSnapshotPacer(monotonicNow: { clock.now })
    }

    @Test("With no measurement the pacer returns the debounce it was given")
    func withNoMeasurementThePacerIsTheExistingDebounce() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        let decision = pacer.armDelay()
        #expect(decision.reason == .unpaced)
        #expect(decision.delayNanoseconds == TaskThreadLiveSnapshotPacer.defaultBaseDebounceNanoseconds)
    }

    @Test("A sub-frame render adds no delay, so small threads keep today's cadence")
    func aCheapRenderAddsNoDelay() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 500_000)
        clock.advance(milliseconds: 121)
        // The sampler's noise floor already discarded the few-millisecond layout
        // pass, so the only measured cost is the synchronous apply body.
        pacer.observe(.none)
        let decision = pacer.reconcileDelay()
        #expect(decision.reason == .debounce)
        #expect(decision.delayNanoseconds == 0)
    }

    @Test("The incident's 700 ms render converges on half the main actor")
    func theIncidentRenderConvergesOnHalfTheMainActor() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)

        // The render blocks the main actor for 700 ms; the 20 Hz probe absorbs
        // it into one overshoot and the request enqueued during the block only
        // reaches the main actor once it ends.
        clock.advance(milliseconds: 700)
        pacer.observe(occupancy(milliseconds: 700))
        let arm = pacer.armDelay()
        #expect(arm.reason == .duty)
        // target = 700 / 0.5 = 1400; elapsed = 700.
        #expect(arm.delayNanoseconds == 700_000_000)

        clock.advance(milliseconds: 700)
        pacer.observe(.none)
        let admit = pacer.reconcileDelay()
        #expect(admit.delayNanoseconds == 0)
        #expect(admit.reason == .debounce)
    }

    @Test("Every drained fragment counts, because the sampler window is read-and-clear")
    func everyDrainedFragmentCounts() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        // Three separate drains inside one period: arm, reconcile, reconcile.
        // Replacing rather than accumulating would report 100 ms and pace at
        // 200 ms instead of 600 ms.
        pacer.observe(occupancy(milliseconds: 100))
        pacer.observe(occupancy(milliseconds: 100))
        pacer.observe(occupancy(milliseconds: 100))
        clock.advance(milliseconds: 100)
        let decision = pacer.reconcileDelay()
        #expect(decision.delayNanoseconds == 500_000_000)
    }

    @Test("A saturated main actor is capped, so an update is always admitted")
    func aSaturatedMainActorIsCapped() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        // 5 s of occupancy would ask for a 10 s period. The clamp is the whole
        // anti-wedge argument: without it the deadline recedes faster than wall
        // time on a fully occupied main actor.
        clock.advance(milliseconds: 500)
        pacer.observe(occupancy(milliseconds: 5_000))
        let held = pacer.reconcileDelay()
        #expect(held.reason == .ceiling)
        #expect(held.delayNanoseconds == 1_500_000_000)

        clock.advance(milliseconds: 1_500)
        pacer.observe(occupancy(milliseconds: 5_000))
        #expect(pacer.reconcileDelay().delayNanoseconds == 0)
    }

    @Test("Reconciling on a fully occupied main actor terminates within the ceiling")
    func reconcilingOnAFullyOccupiedMainActorTerminates() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        var iterations = 0
        var elapsed = 0
        while iterations < 64 {
            iterations += 1
            let decision = pacer.reconcileDelay()
            guard decision.delayNanoseconds > 0 else { break }
            let step = Int(decision.delayNanoseconds / 1_000_000)
            clock.advance(milliseconds: step)
            elapsed += step
            // Adversarial: every millisecond of the wait is also busy.
            pacer.observe(occupancy(milliseconds: step))
        }
        #expect(iterations < 64, "the reconcile loop must terminate")
        #expect(elapsed <= 2_008, "admission must happen inside the ceiling")
    }

    @Test("A terminal apply disarms the pacer so the final transcript is not paced")
    func aTerminalApplyDisarmsThePacer() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        pacer.observe(occupancy(milliseconds: 900))
        #expect(pacer.isPacing)
        pacer.recordApply(isLive: false, synchronousApplyNanoseconds: 0)
        #expect(!pacer.isPacing)
        let decision = pacer.armDelay()
        #expect(decision.reason == .unpaced)
        #expect(decision.delayNanoseconds == TaskThreadLiveSnapshotPacer.defaultBaseDebounceNanoseconds)
    }

    @Test("Telemetry reports the achieved duty cycle, not the requested one")
    func telemetryReportsTheAchievedDutyCycle() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        pacer.observe(occupancy(milliseconds: 500))
        clock.advance(milliseconds: 1_000)
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        let fields = pacer.consumeTelemetryFields()
        #expect(fields["pace_render_ms"] == "500.00")
        #expect(fields["pace_period_ms"] == "1000.00")
        #expect(fields["pace_duty"] == "0.50")

        // Read-and-clear: the held counters belong to one window only.
        let cleared = pacer.consumeTelemetryFields()
        #expect(cleared["deferred_snapshot_count"] == "0")
        #expect(cleared["throttle_delay_ms"] == "0.00")
    }

    @Test("Observing before any apply cannot arm the pacer")
    func observingBeforeAnyApplyCannotArmThePacer() {
        let clock = ManualClock()
        let pacer = makePacer(clock)
        pacer.observe(occupancy(milliseconds: 5_000))
        #expect(!pacer.isPacing)
        // Occupancy recorded while disarmed belongs to whatever else was using
        // the main actor -- a task open, a sidebar rebuild -- and must not be
        // charged to the first live update of a thread that has not rendered
        // once yet.
        #expect(pacer.armDelay().reason == .unpaced)
    }
}
