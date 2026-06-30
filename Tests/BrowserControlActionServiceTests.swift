import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Control Action Service")
struct BrowserControlActionServiceTests {
    @Test("target identifier uses stable priority order")
    func targetIdentifierUsesPriorityOrder() {
        let selectorTarget = BrowserControlActionService.targetIdentifier(
            selector: "#save",
            x: 0.5,
            y: 0.5,
            label: "Save",
            role: "button",
            text: "Save",
            placeholder: "Name",
            testID: "save-button"
        )
        let labelTarget = BrowserControlActionService.targetIdentifier(
            selector: nil,
            x: 0.5,
            y: 0.5,
            label: "Save",
            role: "button",
            text: nil,
            placeholder: nil,
            testID: nil
        )
        let roleTarget = BrowserControlActionService.targetIdentifier(
            selector: nil,
            x: nil,
            y: nil,
            label: nil,
            role: "Button",
            text: nil,
            placeholder: nil,
            testID: nil
        )
        let pointTarget = BrowserControlActionService.targetIdentifier(
            selector: nil,
            x: 0.25,
            y: 0.75,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil
        )

        #expect(selectorTarget.hasPrefix("selector:"))
        #expect(labelTarget.hasPrefix("label:"))
        #expect(roleTarget == "role:button")
        #expect(pointTarget == "point:0.25,0.75")
    }

    @Test("target identifier hashes are deterministic and bounded")
    func targetIdentifierHashesAreDeterministicAndBounded() {
        let first = BrowserControlActionService.targetIdentifier(
            selector: "#save",
            x: nil,
            y: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil
        )
        let second = BrowserControlActionService.targetIdentifier(
            selector: "#save",
            x: nil,
            y: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil
        )

        #expect(first == second)
        #expect(first == "selector:eb065962d402bd0c")
    }

    @Test("target identifier normalizes text based targets before hashing")
    func targetIdentifierNormalizesTextBasedTargetsBeforeHashing() {
        let upper = BrowserControlActionService.targetIdentifier(
            selector: nil,
            x: nil,
            y: nil,
            label: "Save",
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil
        )
        let lower = BrowserControlActionService.targetIdentifier(
            selector: nil,
            x: nil,
            y: nil,
            label: "save",
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil
        )

        #expect(upper == lower)
        #expect(upper.hasPrefix("label:"))
    }

    @Test("bounds signature normalizes numeric fields")
    func boundsSignatureNormalizesNumericFields() {
        let signature = BrowserControlActionService.boundsSignature([
            "x": "10",
            "y": NSNumber(value: 20),
            "width": 30,
            "height": "40"
        ])

        #expect(signature == "10,20,30,40")
        #expect(BrowserControlActionService.boundsSignature(nil).isEmpty)
    }

    @Test("retryable actionability errors are explicit")
    func retryableActionabilityErrorsAreExplicit() {
        #expect(BrowserControlActionService.isRetryableActionabilityError("selector_not_found"))
        #expect(BrowserControlActionService.isRetryableActionabilityError("target_obscured"))
        #expect(!BrowserControlActionService.isRetryableActionabilityError("dangerous_confirmation_required"))
        #expect(!BrowserControlActionService.isRetryableActionabilityError(""))
    }

    @Test("actionability summary preserves target diagnostics")
    func actionabilitySummaryPreservesTargetDiagnostics() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let now = started.addingTimeInterval(1.25)

        let summary = BrowserControlActionService.actionabilityWaitSummary(
            object: [
                "ok": true,
                "visible": NSNumber(value: true),
                "disabled": false,
                "actionable": true,
                "coveredBy": "#overlay",
                "selector": "#save",
                "requestedSelector": "button.primary",
                "label": "Password",
                "name": "current-password",
                "role": "button",
                "tag": "button",
                "type": "password",
                "autocomplete": "current-password",
                "placeholder": "Enter password",
                "testID": "password-field",
                "href": "https://example.com/login",
                "url": "https://example.com",
                "bounds": [
                    "x": 10,
                    "y": 20,
                    "width": 100,
                    "height": 44
                ]
            ],
            attempts: 3,
            stableBoundsSamples: 1,
            timedOut: false,
            started: started,
            now: now
        )

        #expect(summary["ok"] as? Bool == true)
        #expect(summary["elapsedMs"] as? Int == 1_250)
        #expect(summary["attempts"] as? Int == 3)
        #expect(summary["stableBounds"] as? Bool == true)
        #expect(summary["coveredBy"] as? String == "#overlay")
        #expect(summary["selector"] as? String == "#save")
        #expect(summary["requestedSelector"] as? String == "button.primary")
        #expect(summary["label"] as? String == "Password")
        #expect(summary["name"] as? String == "current-password")
        #expect(summary["type"] as? String == "password")
        #expect(summary["autocomplete"] as? String == "current-password")
        #expect(summary["placeholder"] as? String == "Enter password")
        #expect(summary["testID"] as? String == "password-field")
        #expect(summary["href"] as? String == "https://example.com/login")
        #expect(summary["url"] as? String == "https://example.com")

        let bounds = try #require(summary["bounds"] as? [String: Any])
        #expect(bounds["width"] as? Int == 100)
    }
}
