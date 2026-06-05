import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Flight Recorder")
struct BrowserFlightRecorderTests {
    @Test("Request summary redacts navigation URLs and hashes text fields")
    func requestSummaryRedactsNavigationAndHashesText() throws {
        let body = Data(#"{"url":"https://docs.google.com/document/d/abc123/edit?token=secret#frag","text":"private replacement text"}"#.utf8)
        let request = BrowserBridgeRequest(
            method: "POST",
            path: "/navigate",
            headers: [:],
            queryItems: [:],
            body: body
        )

        let summary = BrowserFlightRecorder.requestSummary(for: request)

        #expect(summary["navigationTarget"] as? String == "https://docs.google.com/document/d/abc123/edit")
        #expect(summary["navigationTargetKind"] as? String == "url")
        #expect(summary["textLength"] as? Int == "private replacement text".count)
        #expect(summary["textHash"] as? String != nil)
        #expect(summary["text"] == nil)
    }

    @Test("Recorder keeps bounded first and recent flight steps")
    func recorderKeepsBoundedTimeline() throws {
        var recorder = BrowserFlightRecorder(retainedLimit: 2)
        let before = BrowserFlightPageSnapshot(
            url: "https://drive.google.com/drive/home?auth=secret",
            title: "Drive",
            pageType: "googleDrive"
        )
        let after = BrowserFlightPageSnapshot(
            url: "https://docs.google.com/document/d/1/edit?token=secret",
            title: "Doc",
            pageType: "googleDocsEditor"
        )

        for index in 0..<3 {
            let request = BrowserBridgeRequest(
                method: "POST",
                path: "/click",
                headers: [:],
                queryItems: [:],
                body: Data(#"{"controlID":"ctl_\#(index)"}"#.utf8)
            )
            _ = recorder.record(
                request: request,
                statusCode: 200,
                before: before,
                after: after,
                duration: 0.12,
                result: ["ok": true, "goalSatisfied": index == 2]
            )
        }

        let snapshot = recorder.snapshot()
        let recent = try #require(snapshot["recentSteps"] as? [[String: Any]])
        let first = try #require(snapshot["firstSteps"] as? [[String: Any]])

        #expect(snapshot["totalSteps"] as? Int == 3)
        #expect(snapshot["retainedSteps"] as? Int == 2)
        #expect(recent.count == 2)
        #expect(first.count == 2)
        #expect(snapshot["finalURL"] as? String == "https://docs.google.com/document/d/1/edit")
        #expect(recent.last?["goalSatisfied"] as? Bool == true)
    }

    @Test("Diagnostics state owns flight timeline and last debug capture")
    func diagnosticsStateOwnsFlightTimelineAndLastDebugCapture() throws {
        var diagnostics = BrowserDiagnosticsSessionState()
        let before = BrowserFlightPageSnapshot(
            url: "https://example.com/start?token=secret",
            title: "Start",
            pageType: "web"
        )
        let after = BrowserFlightPageSnapshot(
            url: "https://example.com/end?token=secret",
            title: "End",
            pageType: "web"
        )
        let request = BrowserBridgeRequest(
            method: "POST",
            path: "/click",
            headers: [:],
            queryItems: [:],
            body: Data("{\"selector\":\"#private\"}".utf8)
        )
        let capture: [String: Any] = ["enabled": false, "reason": "debug_capture_disabled"]

        diagnostics.rememberDebugCapture(capture)
        let entry = diagnostics.recordFlightStep(
            request: request,
            statusCode: 500,
            before: before,
            after: after,
            duration: 0.25,
            result: ["ok": false, "error": "target_obscured"],
            lastBrowserTraceID: "trace_1",
            debugCapture: capture
        )
        let trace = diagnostics.traceResponse(lastBrowserTrace: ["id": "trace_1"])
        let flight = try #require(trace["flight"] as? [String: Any])
        let lastDebugCapture = try #require(trace["lastDebugCapture"] as? [String: Any])

        #expect(entry["error"] as? String == "target_obscured")
        #expect(entry["browserTraceID"] as? String == "trace_1")
        #expect(diagnostics.lastFailure == "target_obscured")
        #expect(flight["totalSteps"] as? Int == 1)
        #expect(lastDebugCapture["reason"] as? String == "debug_capture_disabled")

        diagnostics.reset()
        #expect(diagnostics.flightSnapshot["totalSteps"] as? Int == 0)
        #expect(diagnostics.lastDebugCapture == nil)
    }
}
