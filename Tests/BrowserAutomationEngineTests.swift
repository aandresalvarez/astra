import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Automation Engine")
struct BrowserAutomationEngineTests {
    @Test("Engine descriptors keep provider contract separate from implementation details")
    func engineDescriptorsSeparateProviderContractFromImplementationDetails() {
        let embedded = BrowserAutomationEngineDescriptor(kind: .embeddedWebKit)
        let controlled = BrowserAutomationEngineDescriptor(kind: .controlledCDP)
        let playwright = BrowserAutomationEngineDescriptor(kind: .playwrightCDP)

        #expect(embedded.providerToolName == "astra-browser")
        #expect(controlled.providerToolName == "astra-browser")
        #expect(playwright.providerToolName == "astra-browser")

        #expect(embedded.bridgeBackendLabel == "embedded WebKit")
        #expect(controlled.bridgeBackendLabel == "controlled Chromium profile")
        #expect(playwright.bridgeBackendLabel == "Playwright-controlled Chromium profile")

        #expect(embedded.exposesRawDebugEndpoint == false)
        #expect(controlled.exposesRawDebugEndpoint == false)
        #expect(playwright.exposesRawDebugEndpoint == false)
    }

    @Test("Shelf browser engines resolve to automation descriptors")
    func shelfBrowserEnginesResolveToAutomationDescriptors() {
        #expect(ShelfBrowserEngine.embedded.automationDescriptor.kind == .embeddedWebKit)
        #expect(ShelfBrowserEngine.controlled.automationDescriptor.kind == .controlledCDP)
        #expect(ShelfBrowserEngine.embedded.bridgeBackendLabel == ShelfBrowserEngine.embedded.automationDescriptor.bridgeBackendLabel)
        #expect(ShelfBrowserEngine.controlled.bridgeBackendLabel == ShelfBrowserEngine.controlled.automationDescriptor.bridgeBackendLabel)
    }

    @Test("Controlled browser public health redacts raw CDP and profile details")
    func controlledBrowserPublicHealthRedactsRawCDPAndProfileDetails() throws {
        let object = BrowserAutomationEnginePublicState.controlledBrowser(
            isRunning: true,
            runState: "running",
            statusMessage: "Controlled profile connected",
            hasDebugPort: true,
            hasProcessID: true,
            lastErrorMessage: nil
        )

        #expect(object["debugEndpoint"] as? String == "internal")
        #expect(object["profile"] as? String == "astra-managed")
        #expect(object["process"] as? String == "running")
        #expect(object["profilePath"] == nil)
        #expect(object["debugPort"] == nil)
        #expect(object["processID"] == nil)

        let encoded = try jsonString(object)
        #expect(!encoded.contains("49123"))
        #expect(!encoded.contains("/tmp/astra-browser-profile"))
    }

    @Test("Trace evidence summarizes CDP settlement without dropping details")
    func traceEvidenceSummarizesCDPSettlement() throws {
        let evidence = try #require(BrowserAutomationTraceEvidence.settlementEvidence(from: [
            "cdpSettlement": [
                "settled": false,
                "signals": ["metadata.stable"],
                "errors": ["runtime.exception", "network.loading_failed"],
                "elapsedMs": 512
            ]
        ]))

        #expect(evidence["settled"] as? Bool == false)
        #expect(evidence["errors"] as? [String] == ["runtime.exception", "network.loading_failed"])
        #expect(evidence["signalCount"] as? Int == 1)
        #expect(evidence["elapsedMs"] as? Int == 512)
    }

    @Test("Controlled CDP requirement is inferred only from explicit browser engine intent")
    func controlledCDPRequirementIsInferredOnlyFromExplicitBrowserEngineIntent() {
        #expect(BrowserAutomationEngineRequirement.requiredEngine(
            text: "Use the ASTRA Controlled Browser / CDP browser automation engine. Do not use the embedded WebKit browser path."
        ) == .controlledCDP)
        #expect(BrowserAutomationEngineRequirement.requiredEngine(
            text: "Report cdpSettlement.settled after the browser action."
        ) == .controlledCDP)
        #expect(BrowserAutomationEngineRequirement.requiredEngine(
            text: "Use the browser shelf to inspect the current page."
        ) == nil)
        #expect(BrowserAutomationEngineRequirement.requiredEngine(
            text: "Create a CDP report file without browser automation."
        ) == nil)
    }

    @Test("Required engine mismatch fails closed with actionable diagnostics")
    func requiredEngineMismatchFailsClosedWithActionableDiagnostics() throws {
        let response = try #require(BrowserAutomationEngineRequirement.mismatchResponse(
            required: .controlledCDP,
            actual: BrowserAutomationEngineDescriptor(kind: .embeddedWebKit)
        ))

        #expect(response["ok"] as? Bool == false)
        #expect(response["error"] as? String == "browser_engine_requirement_not_met")
        #expect(response["requiredAutomationEngine"] as? String == "controlled-cdp")
        let actual = try #require(response["actualAutomationEngine"] as? [String: Any])
        #expect(actual["kind"] as? String == "embedded-webkit")
        #expect((response["message"] as? String)?.contains("Controlled Browser") == true)

        #expect(BrowserAutomationEngineRequirement.mismatchResponse(
            required: .controlledCDP,
            actual: BrowserAutomationEngineDescriptor(kind: .controlledCDP)
        ) == nil)
    }

    @Test("Bridge policy converts required engine header mismatch into route diagnostics")
    func bridgePolicyConvertsRequiredEngineHeaderMismatchIntoRouteDiagnostics() throws {
        let request = BrowserBridgeRequest(
            method: "POST",
            path: "/click",
            headers: [
                BrowserAutomationEngineRequirement.headerName.lowercased(): "controlled-cdp"
            ],
            queryItems: [:],
            body: Data()
        )

        let response = try #require(BrowserAutomationEngineRequirementBridgePolicy.mismatchResponse(
            for: request,
            actual: BrowserAutomationEngineDescriptor(kind: .embeddedWebKit),
            backend: "embedded WebKit",
            controlledBrowserRunning: false,
            controlledBrowserState: "stopped",
            controlledBrowserStatus: "Controlled browser stopped"
        ))

        #expect(response["error"] as? String == "browser_engine_requirement_not_met")
        #expect(response["route"] as? String == "POST /click")
        #expect(response["backend"] as? String == "embedded WebKit")
        #expect(response["controlledBrowserRunning"] as? Bool == false)
        #expect(response["controlledBrowserState"] as? String == "stopped")
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}
