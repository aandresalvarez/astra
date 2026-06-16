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

    func traceResponse(lastBrowserTrace: [String: Any]?, full: Bool = false) -> [String: Any] {
        if full {
            return [
                "ok": true,
                "trace": lastBrowserTrace ?? NSNull(),
                "flight": flightSnapshot,
                "lastDebugCapture": lastDebugCapture ?? NSNull()
            ]
        }

        return [
            "ok": true,
            "trace": compactTrace(lastBrowserTrace),
            "flight": compactFlight(flightSnapshot),
            "lastDebugCapture": compactDebugCapture(lastDebugCapture)
        ]
    }

    mutating func rememberDebugCapture(_ capture: [String: Any]) {
        lastDebugCapture = capture
    }

    private func compactTrace(_ trace: [String: Any]?) -> Any {
        guard let trace else { return NSNull() }
        var compact: [String: Any] = [:]
        for key in [
            "id",
            "createdAt",
            "action",
            "engine",
            "backend",
            "executed",
            "expectedOutcome",
            "observedOutcome",
            "goalSatisfied",
            "outcomeVerified",
            "resultOK",
            "resultError",
            "cdpSettled",
            "cdpSettlementErrors",
            "risk",
            "requiresUserConfirmation"
        ] {
            if let value = trace[key] {
                compact[key] = value
            }
        }
        if let beforeURL = trace["beforeURL"] as? String {
            compact["beforeURL"] = BrowserFlightPageSnapshot.redactedURLString(beforeURL)
        }
        if let afterURL = trace["afterURL"] as? String {
            compact["afterURL"] = BrowserFlightPageSnapshot.redactedURLString(afterURL)
        }
        if let beforeTitle = trace["beforeTitle"] as? String {
            compact["beforeTitle"] = String(beforeTitle.prefix(160))
        }
        if let afterTitle = trace["afterTitle"] as? String {
            compact["afterTitle"] = String(afterTitle.prefix(160))
        }
        if let controlID = trace["controlID"] as? String, !controlID.isEmpty {
            compact["controlID"] = controlID
        }
        if let settlement = trace["cdpSettlement"] as? [String: Any] {
            compact["cdpSettlement"] = compactSettlement(settlement)
        }
        return compact
    }

    private func compactFlight(_ flight: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]
        for key in [
            "ok",
            "totalSteps",
            "retainedSteps",
            "retainedLimit",
            "lastError",
            "finalTitle",
            "finalPageType"
        ] {
            if let value = flight[key] {
                compact[key] = value
            }
        }
        if let finalURL = flight["finalURL"] as? String {
            compact["finalURL"] = BrowserFlightPageSnapshot.redactedURLString(finalURL)
        }
        if let lastStep = flight["lastStep"] as? [String: Any] {
            compact["lastStep"] = compactFlightStep(lastStep)
        }
        return compact
    }

    private func compactFlightStep(_ step: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]
        for key in [
            "id",
            "sequence",
            "createdAt",
            "command",
            "method",
            "path",
            "statusCode",
            "durationMs",
            "ok",
            "error",
            "message",
            "goalSatisfied",
            "outcomeVerified",
            "observedOutcome",
            "expectedOutcome",
            "outcomeReason",
            "browserTraceID"
        ] {
            if let value = step[key] {
                compact[key] = value
            }
        }
        if let request = step["request"] as? [String: Any] {
            compact["request"] = request
        }
        return compact
    }

    private func compactDebugCapture(_ capture: [String: Any]?) -> Any {
        guard let capture else { return NSNull() }
        var compact: [String: Any] = [:]
        for key in ["enabled", "scope", "source", "reason"] {
            if let value = capture[key] {
                compact[key] = value
            }
        }
        if let trigger = capture["trigger"] as? [String: Any] {
            compact["trigger"] = compactFlightStep(trigger)
        }
        if let page = capture["page"] as? [String: Any] {
            var compactPage: [String: Any] = [:]
            if let url = page["url"] as? String {
                compactPage["url"] = BrowserFlightPageSnapshot.redactedURLString(url)
            }
            for key in ["title", "pageType", "host"] {
                if let value = page[key] {
                    compactPage[key] = value
                }
            }
            compact["page"] = compactPage
        }
        if let errors = capture["captureErrors"] {
            compact["captureErrors"] = errors
        }
        return compact.isEmpty ? NSNull() : compact
    }

    private func compactSettlement(_ settlement: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]
        for key in [
            "engine",
            "action",
            "settled",
            "urlChanged",
            "titleChanged",
            "accessibilityRefreshed",
            "signalCount",
            "errorCount",
            "signals",
            "errors",
            "elapsedMs"
        ] {
            if let value = settlement[key] {
                compact[key] = value
            }
        }
        return compact
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
