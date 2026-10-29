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

// MARK: - Right-side panel fields

extension ScreenTransitionTelemetryTests {
    @Test("Direction reads open, close, switch or none from the panels before and after")
    func directionFromPanels() {
        #expect(ScreenTransitionDirection.resolve(previousPanel: nil, nextPanel: "context_rail") == "open")
        #expect(ScreenTransitionDirection.resolve(previousPanel: "shelf_markdown", nextPanel: nil) == "close")
        #expect(ScreenTransitionDirection.resolve(previousPanel: "shelf_markdown", nextPanel: "context_rail") == "switch")
        #expect(ScreenTransitionDirection.resolve(previousPanel: "shelf_browser", nextPanel: "shelf_browser") == "none")
        #expect(ScreenTransitionDirection.resolve(previousPanel: nil, nextPanel: nil) == "none")
    }

    @Test("A transition reports how far the transcript's width moved and in which mode")
    func traceReportsLayoutDelta() {
        var trace = ScreenTransitionTrace(
            traceID: "screen-transition-layout",
            destination: "context_rail",
            source: "rail_toggle",
            taskID: nil,
            startedAtUptimeNanoseconds: 10_000_000,
            context: ["direction": "open", "run_count": "90", "input_count": "3"],
            layoutBefore: ScreenTransitionLayout(mode: "detailOnly", detailWidth: 1_400, panelWidth: 0)
        )
        // A report identical to the layout before the change is not the
        // transition's layout; the first different one is, and later ones are
        // not attributed.
        trace.recordLayout(ScreenTransitionLayout(mode: "detailOnly", detailWidth: 1_400, panelWidth: 0))
        trace.recordLayout(ScreenTransitionLayout(mode: "dockedContext", detailWidth: 1_060, panelWidth: 340))
        trace.recordLayout(ScreenTransitionLayout(mode: "dockedContext", detailWidth: 900, panelWidth: 500))

        let fields = trace.result(at: 60_000_000).fields
        #expect(fields["layout_mode"] == "dockedContext")
        #expect(fields["detail_width_before"] == "1400")
        #expect(fields["detail_width_after"] == "1060")
        #expect(fields["detail_width_delta"] == "340")
        #expect(fields["panel_width"] == "340")
        #expect(fields["direction"] == "open")
        #expect(fields["run_count"] == "90")
        #expect(fields["input_count"] == "3")
        // The lifecycle's own fields win over any context key that collides.
        #expect(fields["destination"] == "context_rail")
    }

    @Test("A transition with no layout report says so instead of inventing zeros")
    func traceWithoutLayoutIsHonest() {
        let trace = ScreenTransitionTrace(
            traceID: "screen-transition-nolayout",
            destination: "shelf_browser",
            source: "shelf_action",
            taskID: nil,
            startedAtUptimeNanoseconds: 0
        )
        let fields = trace.result(at: 1_000_000).fields
        #expect(fields["layout_mode"] == "not_recorded")
        #expect(fields["detail_width_delta"] == "not_recorded")
        #expect(fields["detail_width_before"] == "not_recorded")
        #expect(fields["direction"] == nil)
    }
}
