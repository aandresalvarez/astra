import Foundation
import Testing
@testable import ASTRA

/// The watchdog exists because a wedged app is the one state ASTRA's telemetry
/// cannot describe: every other call site measures a scope it eventually
/// leaves, and a SwiftUI AttributeGraph live-lock never leaves one. So the only
/// thing worth pinning here is that a main thread which stops servicing its run
/// loop actually gets reported, from a queue the stall cannot reach.
@Suite("Main-thread stall monitor")
struct MainThreadStallMonitorTests {
    @MainActor
    @Test("A blocked main thread is reported by the background watchdog")
    func blockedMainThreadIsReported() {
        let monitor = MainThreadStallMonitor(stallThreshold: 0.2, pollInterval: 0.05)
        monitor.start()
        defer { monitor.stop() }

        #expect(monitor.reportedStallCountForTesting == 0)
        // Blocking, not `await`: yielding would let the run loop turn and the
        // heartbeat land, which is the case that must *not* report.
        Thread.sleep(forTimeInterval: 1.0)
        #expect(monitor.reportedStallCountForTesting >= 1)
    }

    @MainActor
    @Test("An idle run loop is not mistaken for a wedged one")
    func idleMainThreadIsNotReported() {
        let monitor = MainThreadStallMonitor(stallThreshold: 0.2, pollInterval: 0.05)
        monitor.start()
        defer { monitor.stop() }

        // Servicing the run loop with nothing to do parks it in
        // `.beforeWaiting` and it stops stamping — which is what a wedge looks
        // like from the timestamp alone. An app the user has left alone in the
        // background must not fill the error channel.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        #expect(monitor.reportedStallCountForTesting == 0)
    }

    @MainActor
    @Test("Starting twice installs one watchdog")
    func startIsIdempotent() {
        let monitor = MainThreadStallMonitor(stallThreshold: 5.0, pollInterval: 0.05)
        monitor.start()
        monitor.start()
        monitor.stop()
        // A second observer left on the main run loop would outlive `stop()`
        // and keep beating into a monitor nothing owns any more.
        monitor.stop()
    }

    @Test("A heartbeat that lands mid-check reports zero, not 584 years")
    func outOfOrderTimestampsSaturate() {
        // What production logged on this monitor's first launch:
        // `duration_ms=18446744073709.55`, which is `UInt64.max` nanoseconds —
        // the watchdog sampled the clock, the main thread stamped a newer
        // heartbeat before the watchdog got the lock, and `&-` wrapped.
        #expect(MainThreadStallMonitor.seconds(from: 500, to: 100) == 0)
        #expect(MainThreadStallMonitor.seconds(from: 100, to: 100) == 0)
        #expect(MainThreadStallMonitor.seconds(from: 0, to: 2_500_000_000) == 2.5)
    }

    @Test("Memory is sampled from the kernel, not guessed")
    func memoryFootprintIsReadable() {
        let memory = MainThreadStallMonitor.memoryFootprint()
        // The two numbers that separate ASTRA's two freeze signatures. A zero
        // here means `task_info` failed and every stall report is blind.
        #expect(memory.residentMegabytes > 0)
        #expect(memory.footprintMegabytes > 0)
    }

    @Test("A stall line names where the main thread was, not just that it stalled")
    func stallFieldsCarryLocation() {
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 7.6,
            memory: (residentMegabytes: 940, footprintMegabytes: 812),
            activity: .afterWaiting,
            phase: .inside(label: "render_task_thread", depth: 2)
        )
        // Everything the previous format carried, unchanged — existing log
        // searches and the footprint comparison that separates the two freeze
        // signatures both keep working.
        #expect(fields["stalled_s"] == "7.6")
        #expect(fields["rss_mb"] == "940")
        #expect(fields["footprint_mb"] == "812")
        // ...plus the two that turn a report into a starting point.
        #expect(fields["phase"] == "render_task_thread")
        #expect(fields["phase_depth"] == "2")
        #expect(fields["run_loop_activity"] == "after_waiting")
    }

    @Test("The stall line reports the phase from detection, not from report time")
    func phaseIsCapturedAtDetection() {
        // The window this guards: `check` releases the monitor lock, then the
        // report path samples memory through a `task_info` syscall. A stall that
        // ends in there has already unwound its scope, so reading the phase
        // afterwards would attach `none` — or an unrelated scope entered during
        // the recovery — to a duration describing the wedge that just ended.
        //
        // Asserted purely on the supplied value. An earlier revision reset the
        // process-global marker here to prove the point, which was itself a
        // race: this test is not `@MainActor`, so under a full run it can
        // execute beside a `@MainActor` test that is inside an instrumented
        // scope, and clearing the shared stack would strand that scope's `pop`
        // and break an unrelated suite.
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 3.2,
            memory: (residentMegabytes: 129, footprintMegabytes: 307),
            activity: .afterWaiting,
            phase: .inside(label: "build_thread_snapshot", depth: 1)
        )
        #expect(fields["phase"] == "build_thread_snapshot")
        #expect(fields["phase"] != "none")
    }

    @Test("The recovery line claims no phase")
    func recoveryLineOmitsPhase() {
        // It is emitted after the run loop turns again, so the wedged scope has
        // already unwound. Naming whatever is open by then would read as the
        // culprit and would not be one.
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 7.7,
            memory: (residentMegabytes: 940, footprintMegabytes: 812),
            activity: .beforeSources,
            phase: nil
        )
        #expect(fields["phase"] == nil)
        #expect(fields["phase_depth"] == nil)
        #expect(fields["run_loop_activity"] == "before_sources")
    }

    @Test("An unreadable phase stays unavailable rather than becoming stale")
    func unavailablePhaseSurvivesValidation() {
        // A revision of this PR validated every reading against the phase
        // stack's generation, including the unavailable one — whose generation
        // is a sentinel that matches nothing once any scope has run. That made
        // `phase=unavailable` unreachable in production: every lock contention
        // was relabelled `stale`, which claims something different and weaker.
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 3.1,
            memory: (residentMegabytes: 100, footprintMegabytes: 90),
            activity: .afterWaiting,
            phase: .unavailable
        )
        #expect(fields["phase"] == "unavailable")
        #expect(fields["phase"] != "stale")
    }

    @Test("A phase that stopped describing the stall is reported as stale")
    func stalePhaseIsDistinctFromBothIdleAndUnavailable() {
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 3.1,
            memory: (residentMegabytes: 100, footprintMegabytes: 90),
            activity: .afterWaiting,
            phase: .stale
        )
        // Three distinguishable answers, because they send an investigation to
        // three different places: a named scope, "not in instrumented code",
        // and "the monitor could not vouch for what it read".
        #expect(fields["phase"] == "stale")
        #expect(fields["phase_depth"] == nil)
    }

    @Test("A stall outside every instrumented scope says so explicitly")
    func stallOutsideInstrumentedScopes() {
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 3.1,
            memory: (residentMegabytes: 100, footprintMegabytes: 90),
            activity: .beforeWaiting,
            phase: .idle
        )
        // Not an absent key: "the wedge is somewhere this app does not measure"
        // is a real answer that sends the search to SwiftUI/AppKit internals,
        // and it must be distinguishable from a monitor that recorded nothing.
        #expect(fields["phase"] == "none")
        #expect(fields["phase_depth"] == nil)
    }

    @Test("Every run-loop stage reports as a distinct token")
    func runLoopActivityIsNamed() {
        // The stage narrows the search on its own: a wedge in `after_waiting`
        // is a source callback, one in `before_timers` is a timer handler.
        // Collapsing any pair into one token would lose that.
        let named: [CFRunLoopActivity] = [
            .entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit
        ]
        let tokens = named.map { MainThreadStallMonitor.activityName($0) }
        #expect(Set(tokens).count == named.count)
        #expect(!tokens.contains("unknown"))
        // Reachable: the monitor can report before the run loop has stamped
        // anything, and an empty option set must not read as a real stage.
        #expect(MainThreadStallMonitor.activityName([]) == "unknown")
    }
}
