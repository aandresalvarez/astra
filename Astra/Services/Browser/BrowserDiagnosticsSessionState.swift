import Foundation

struct BrowserDiagnosticsSessionState {
    private var flightRecorder = BrowserFlightRecorder()
    private(set) var lastDebugCapture: [String: Any]?

    mutating func reset() {
        flightRecorder.reset()
        lastDebugCapture = nil
    }

    var flightSnapshot: [String: Any] {
        flightRecorder.snapshot()
    }

    var lastFailure: String? {
        flightSnapshot["lastError"] as? String
    }

    func traceResponse(lastBrowserTrace: [String: Any]?) -> [String: Any] {
        [
            "ok": true,
            "trace": lastBrowserTrace ?? NSNull(),
            "flight": flightSnapshot,
            "lastDebugCapture": lastDebugCapture ?? NSNull()
        ]
    }

    mutating func rememberDebugCapture(_ capture: [String: Any]) {
        lastDebugCapture = capture
    }

    mutating func recordFlightStep(
        request: BrowserBridgeRequest,
        statusCode: Int,
        before: BrowserFlightPageSnapshot,
        after: BrowserFlightPageSnapshot,
        duration: TimeInterval,
        result: [String: Any]?,
        lastBrowserTraceID: String?,
        debugCapture: [String: Any]?
    ) -> [String: Any] {
        let runGuard = result?["runGuard"] as? [String: Any]
        return flightRecorder.record(
            request: request,
            statusCode: statusCode,
            before: before,
            after: after,
            duration: duration,
            result: result,
            runGuard: runGuard,
            lastBrowserTraceID: lastBrowserTraceID,
            debugCapture: debugCapture
        )
    }
}
