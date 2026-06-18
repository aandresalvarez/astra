import Foundation

struct ControlledBrowserActionSettlementResult: Equatable {
    let action: String
    let isSettled: Bool
    let urlChanged: Bool
    let titleChanged: Bool
    let accessibilityRefreshed: Bool
    let signals: [String]
    let errors: [String]
    let elapsedMs: Int

    var jsonObject: [String: Any] {
        [
            "engine": BrowserAutomationEngineKind.controlledCDP.rawValue,
            "action": action,
            "settled": isSettled,
            "urlChanged": urlChanged,
            "titleChanged": titleChanged,
            "accessibilityRefreshed": accessibilityRefreshed,
            "signals": signals,
            "errors": errors,
            "elapsedMs": elapsedMs
        ]
    }
}

struct ControlledBrowserActionSettlementWaitDecision: Equatable {
    let shouldContinue: Bool
    let reason: String
}

enum ControlledBrowserActionSettlement {
    static func evaluate(
        action: String,
        beforeURL: String,
        beforeTitle: String,
        afterURL: String,
        afterTitle: String,
        events: [[String: Any]],
        accessibilityNodeCount: Int,
        elapsedMs: Int
    ) -> ControlledBrowserActionSettlementResult {
        let urlChanged = meaningfulChange(from: beforeURL, to: afterURL)
        let titleChanged = meaningfulChange(from: beforeTitle, to: afterTitle)
        let accessibilityRefreshed = accessibilityNodeCount > 0
        let eventSignals = signals(from: events)
        let eventErrors = errors(from: events)
        var signals = eventSignals

        if !urlChanged && !titleChanged {
            signals.append("metadata.stable")
        }
        if urlChanged {
            signals.append("metadata.url_changed")
        }
        if titleChanged {
            signals.append("metadata.title_changed")
        }
        if accessibilityRefreshed {
            signals.append("accessibility.refreshed")
        }

        let uniqueSignals = orderedUnique(signals)
        let uniqueErrors = orderedUnique(eventErrors)
        let hasReadySignal = hasReadySignal(uniqueSignals)

        return ControlledBrowserActionSettlementResult(
            action: action,
            isSettled: uniqueErrors.isEmpty && hasReadySignal,
            urlChanged: urlChanged,
            titleChanged: titleChanged,
            accessibilityRefreshed: accessibilityRefreshed,
            signals: uniqueSignals,
            errors: uniqueErrors,
            elapsedMs: elapsedMs
        )
    }

    static func waitDecision(
        events: [[String: Any]],
        accessibilityNodeCount: Int,
        elapsedMs: Int,
        maxWaitMs: Int
    ) -> ControlledBrowserActionSettlementWaitDecision {
        let uniqueErrors = orderedUnique(errors(from: events))
        if !uniqueErrors.isEmpty {
            return ControlledBrowserActionSettlementWaitDecision(
                shouldContinue: false,
                reason: "cdp_error"
            )
        }

        let uniqueSignals = orderedUnique(signals(from: events))
        let accessibilityRefreshed = accessibilityNodeCount > 0
        if accessibilityRefreshed && hasReadySignal(uniqueSignals) {
            return ControlledBrowserActionSettlementWaitDecision(
                shouldContinue: false,
                reason: "settled"
            )
        }

        if accessibilityRefreshed && elapsedMs >= 300 {
            return ControlledBrowserActionSettlementWaitDecision(
                shouldContinue: false,
                reason: "accessibility_refreshed"
            )
        }

        if elapsedMs >= maxWaitMs {
            return ControlledBrowserActionSettlementWaitDecision(
                shouldContinue: false,
                reason: "deadline"
            )
        }

        return ControlledBrowserActionSettlementWaitDecision(
            shouldContinue: true,
            reason: "waiting_for_signal"
        )
    }

    private static func signals(from events: [[String: Any]]) -> [String] {
        events.compactMap { event in
            let method = ControlledBrowserCDPTransport.stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Page.lifecycleEvent":
                let name = ControlledBrowserCDPTransport.stringValue(params["name"])
                return name.isEmpty ? "page.lifecycle" : "page.lifecycle.\(normalizedSignalName(name))"
            case "Page.loadEventFired":
                return "page.load"
            case "Page.domContentEventFired":
                return "page.dom_content"
            case "Page.frameNavigated":
                return "page.frame_navigated"
            case "Runtime.consoleAPICalled":
                return "runtime.console"
            default:
                return nil
            }
        }
    }

    private static func errors(from events: [[String: Any]]) -> [String] {
        events.compactMap { event in
            let method = ControlledBrowserCDPTransport.stringValue(event["method"])
            switch method {
            case "Runtime.exceptionThrown":
                return "runtime.exception"
            case "Network.loadingFailed":
                return "network.loading_failed"
            default:
                if let error = event["error"] as? [String: Any], !error.isEmpty {
                    return "cdp.error"
                }
                return nil
            }
        }
    }

    private static func meaningfulChange(from before: String, to after: String) -> Bool {
        let lhs = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = after.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhs.isEmpty && !rhs.isEmpty && lhs != rhs
    }

    private static func normalizedSignalName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func hasReadySignal(_ signals: [String]) -> Bool {
        signals.contains { signal in
            signal.hasPrefix("page.lifecycle.")
                || signal == "page.load"
                || signal == "page.dom_content"
                || signal == "metadata.url_changed"
                || signal == "metadata.title_changed"
                || signal == "accessibility.refreshed"
                || signal == "metadata.stable"
        }
    }
}
