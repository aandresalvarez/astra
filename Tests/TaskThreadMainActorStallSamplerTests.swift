import Foundation
import Testing
@testable import ASTRA

/// Blocking the calling thread is the point of these tests, so it is wrapped in
/// a synchronous function: `Thread.sleep` called directly from an `async` body
/// is a warning today and an error under the Swift 6 language mode.
private func blockCallingThread(forSeconds seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

@Suite("Task thread main actor stall sampler")
@MainActor
struct TaskThreadMainActorStallSamplerTests {
    @Test("A wake on schedule reports no stall")
    func aWakeOnScheduleReportsNoStall() {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.record(wakeGapNanoseconds: TaskThreadMainActorStallSampler.probeIntervalNanoseconds)
        #expect(sampler.maxOvershootMilliseconds == 0)
        #expect(sampler.hitchCount == 0)
        #expect(sampler.probeCount == 1)
    }

    @Test("A blocked main actor is reported as overshoot, not as a missed probe")
    func aBlockedMainActorIsReportedAsOvershoot() {
        let sampler = TaskThreadMainActorStallSampler()
        // A 6 s block on a 50 ms probe: the shape of the worst production
        // cadence sample, where 74% of the span was an unexplained main-actor
        // hop and no instrument reported anything at all.
        sampler.record(wakeGapNanoseconds: 6_050_000_000)
        #expect(sampler.maxOvershootMilliseconds == 6_000)
        #expect(sampler.hitchCount == 1)
    }

    @Test("Overshoot reports the worst wake in the window, not the last one")
    func overshootReportsTheWorstWakeInTheWindow() {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.record(wakeGapNanoseconds: 1_050_000_000)
        sampler.record(wakeGapNanoseconds: 51_000_000)
        #expect(sampler.maxOvershootMilliseconds == 1_000)
        #expect(sampler.hitchCount == 1)
        #expect(sampler.probeCount == 2)
    }

    @Test("Consuming the fields clears the window so cadence samples do not double count")
    func consumingTheFieldsClearsTheWindow() {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.record(wakeGapNanoseconds: 350_000_000)
        let fields = sampler.consumeTelemetryFields()
        #expect(fields["main_actor_max_stall_ms"] == "300.00")
        #expect(fields["main_actor_hitch_count"] == "1")
        #expect(fields["main_actor_probe_count"] == "1")

        let cleared = sampler.consumeTelemetryFields()
        #expect(cleared["main_actor_max_stall_ms"] == "0.00")
        #expect(cleared["main_actor_hitch_count"] == "0")
        #expect(cleared["main_actor_probe_count"] == "0")
    }

    @Test("A real main actor block is observed by the running probe")
    func aRealMainActorBlockIsObservedByTheRunningProbe() async throws {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.start()
        #expect(sampler.isRunning)
        // Wait for the probe to be scheduled at all before blocking. Asserting
        // straight after `start()` measures whether the whole suite happens to
        // be contending for the main actor, not whether the probe works.
        try await waitForProbe(after: 0, on: sampler)

        // Hold the main actor past several probe intervals. The probe cannot
        // run while this executes, so its next wake must report the overshoot.
        let blockedAfter = sampler.probeCount
        blockCallingThread(forSeconds: 0.3)
        try await waitForProbe(after: blockedAfter, on: sampler)

        sampler.stop()
        #expect(!sampler.isRunning)
        #expect(sampler.maxOvershootMilliseconds >= 100)
    }

    private func waitForProbe(
        after count: Int,
        on sampler: TaskThreadMainActorStallSampler
    ) async throws {
        for _ in 0..<200 where sampler.probeCount <= count {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try #require(sampler.probeCount > count, "the probe never woke")
    }

    @Test("The control window and the telemetry window drain independently")
    func theControlAndTelemetryWindowsDrainIndependently() {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.record(wakeGapNanoseconds: 750_000_000)

        // The pacer drains on every scheduling decision; the cadence line drains
        // at most once a second. Sharing one accumulator is how the incident hid
        // itself, so prove neither consumer can blind the other.
        let control = sampler.consumeControlWindow()
        #expect(control.busyMilliseconds == 700)
        #expect(sampler.consumeControlWindow().busyNanoseconds == 0)

        let telemetry = sampler.consumeTelemetryFields()
        #expect(telemetry["main_actor_max_stall_ms"] == "700.00")
        #expect(telemetry["main_actor_hitch_count"] == "1")
    }

    @Test("Sub-frame wake jitter is not counted as occupancy")
    func subFrameJitterIsNotCountedAsOccupancy() {
        let sampler = TaskThreadMainActorStallSampler()
        // 20 wakes each 2 ms late on a completely idle main actor: a whole
        // second of probing. Summed naively this forges 40 ms of "busy" and
        // makes the pacer throttle a thread that is doing nothing.
        for _ in 0..<20 {
            sampler.record(
                wakeGapNanoseconds: TaskThreadMainActorStallSampler.probeIntervalNanoseconds + 2_000_000
            )
        }
        #expect(sampler.consumeControlWindow().busyNanoseconds == 0)
        // The telemetry window is unchanged: it still reports the worst wake.
        #expect(sampler.maxOvershootMilliseconds == 2)
    }

    @Test("The control window sums every block in the window")
    func theControlWindowSumsEveryBlock() {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.record(wakeGapNanoseconds: 750_000_000)   // 700 ms render
        sampler.record(wakeGapNanoseconds: 70_000_000)    //  20 ms merge
        sampler.record(wakeGapNanoseconds: 65_000_000)    //  15 ms pre-read save
        let control = sampler.consumeControlWindow()
        #expect(control.busyMilliseconds == 735)
        #expect(control.longestBlockMilliseconds == 700)
    }

    @Test("Stopping the sampler leaves no probe behind")
    func stoppingTheSamplerLeavesNoProbeBehind() async throws {
        let sampler = TaskThreadMainActorStallSampler()
        sampler.start()
        sampler.stop()
        #expect(!sampler.isRunning)
        try await Task.sleep(nanoseconds: 150_000_000)
        // A leaked 20 Hz wakeup would have logged several probes by now.
        #expect(sampler.probeCount == 0)
    }
}
