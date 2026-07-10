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
}
