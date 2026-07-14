import Foundation
import Testing
@testable import ASTRA

@Suite("Screen transition telemetry")
struct ScreenTransitionTelemetryTests {
    @Test("View ready result has only safe transition fields")
    func traceProducesSafeResult() {
        let taskID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let trace = ScreenTransitionTrace(
            traceID: "screen-transition-01234567",
            destination: "shelf_markdown",
            source: "shelf_action",
            taskID: taskID,
            startedAtUptimeNanoseconds: 10_000_000
        )

        let result = trace.result(at: 85_000_000)

        #expect(result.event == "screen_transition_to_view_ready")
        #expect(result.durationMilliseconds == 75)
        #expect(result.fields["destination"] == "shelf_markdown")
        #expect(result.fields["task_id"] == "01234567")
        #expect(result.fields["title"] == nil)
    }

    @Test("Transition phases distinguish state commit from main-actor stalls")
    func traceRecordsCommitAndProbePhases() {
        var trace = ScreenTransitionTrace(
            traceID: "screen-transition-phases",
            destination: "shelf_markdown",
            source: "shelf_action",
            taskID: nil,
            startedAtUptimeNanoseconds: 10_000_000
        )
        trace.markStateCommitted(at: 15_000_000)
        trace.recordMainActorProbe(at: 30_000_000)
        trace.recordMainActorProbe(at: 95_000_000)

        let result = trace.result(at: 110_000_000)

        #expect(result.fields["state_commit_ms"] == "5.00")
        #expect(result.fields["state_to_view_ready_ms"] == "95.00")
        #expect(result.fields["max_main_actor_probe_gap_ms"] == "65.00")
        #expect(result.fields["main_actor_hitch_count"] == "1")
    }
}
