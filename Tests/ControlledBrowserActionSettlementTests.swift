import Foundation
import Testing
@testable import ASTRA

@Suite("Controlled Browser Action Settlement")
struct ControlledBrowserActionSettlementTests {
    @Test("Settlement classifies lifecycle and accessibility refresh as ready")
    func settlementClassifiesLifecycleAndAccessibilityRefreshAsReady() {
        let result = ControlledBrowserActionSettlement.evaluate(
            action: "click",
            beforeURL: "https://example.com/start",
            beforeTitle: "Start",
            afterURL: "https://example.com/next",
            afterTitle: "Next",
            events: [
                ["method": "Page.lifecycleEvent", "params": ["name": "networkAlmostIdle"]],
                ["method": "Page.loadEventFired", "params": [:]]
            ],
            accessibilityNodeCount: 42,
            elapsedMs: 230
        )

        #expect(result.isSettled)
        #expect(result.urlChanged)
        #expect(result.titleChanged)
        #expect(result.accessibilityRefreshed)
        #expect(result.signals.contains("page.lifecycle.networkAlmostIdle"))
        #expect(result.signals.contains("page.load"))
        #expect(result.jsonObject["engine"] as? String == "controlled-cdp")
    }

    @Test("Settlement surfaces runtime and network failures even when page stabilizes")
    func settlementSurfacesRuntimeAndNetworkFailures() {
        let result = ControlledBrowserActionSettlement.evaluate(
            action: "type",
            beforeURL: "https://example.com/form",
            beforeTitle: "Form",
            afterURL: "https://example.com/form",
            afterTitle: "Form",
            events: [
                ["method": "Runtime.exceptionThrown", "params": ["exceptionDetails": ["text": "boom"]]],
                ["method": "Network.loadingFailed", "params": ["errorText": "net::ERR_FAILED"]]
            ],
            accessibilityNodeCount: 0,
            elapsedMs: 512
        )

        #expect(result.isSettled == false)
        #expect(result.errors.contains("runtime.exception"))
        #expect(result.errors.contains("network.loading_failed"))
        #expect(result.signals.contains("metadata.stable"))
        #expect(result.jsonObject["errors"] as? [String] == ["runtime.exception", "network.loading_failed"])
    }

    @Test("Wait policy continues until readiness, failure, or deadline")
    func waitPolicyContinuesUntilReadinessFailureOrDeadline() {
        let waiting = ControlledBrowserActionSettlement.waitDecision(
            events: [],
            accessibilityNodeCount: 0,
            elapsedMs: 150,
            maxWaitMs: 1_500
        )
        #expect(waiting.shouldContinue)
        #expect(waiting.reason == "waiting_for_signal")

        let ready = ControlledBrowserActionSettlement.waitDecision(
            events: [["method": "Page.lifecycleEvent", "params": ["name": "networkIdle"]]],
            accessibilityNodeCount: 12,
            elapsedMs: 320,
            maxWaitMs: 1_500
        )
        #expect(ready.shouldContinue == false)
        #expect(ready.reason == "settled")

        let failed = ControlledBrowserActionSettlement.waitDecision(
            events: [["method": "Runtime.exceptionThrown", "params": [:]]],
            accessibilityNodeCount: 0,
            elapsedMs: 180,
            maxWaitMs: 1_500
        )
        #expect(failed.shouldContinue == false)
        #expect(failed.reason == "cdp_error")

        let refreshed = ControlledBrowserActionSettlement.waitDecision(
            events: [],
            accessibilityNodeCount: 8,
            elapsedMs: 300,
            maxWaitMs: 1_500
        )
        #expect(refreshed.shouldContinue == false)
        #expect(refreshed.reason == "accessibility_refreshed")

        let deadline = ControlledBrowserActionSettlement.waitDecision(
            events: [],
            accessibilityNodeCount: 0,
            elapsedMs: 1_500,
            maxWaitMs: 1_500
        )
        #expect(deadline.shouldContinue == false)
        #expect(deadline.reason == "deadline")
    }
}
