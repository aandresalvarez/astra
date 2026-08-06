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
