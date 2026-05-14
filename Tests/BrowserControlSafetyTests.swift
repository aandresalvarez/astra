import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Control Safety")
struct BrowserControlSafetyTests {
    @Test("Google Docs select-all delete sequence is blocked")
    func googleDocsSelectAllDeleteSequenceIsBlocked() {
        var state = BrowserKeypressSafetyState()
        let now = Date()
        let url = "https://docs.google.com/document/d/example/edit"

        let selectAll = BrowserKeypressSafety.evaluate(
            key: "a",
            modifiers: ["command"],
            currentURL: url,
            isGoogleWorkspaceEditor: true,
            state: &state,
            now: now
        )
        let delete = BrowserKeypressSafety.evaluate(
            key: "Backspace",
            modifiers: [],
            currentURL: url,
            isGoogleWorkspaceEditor: true,
            state: &state,
            now: now.addingTimeInterval(1)
        )

        #expect(selectAll.allowed)
        #expect(!delete.allowed)
        #expect(delete.error == "dangerous_keypress_sequence")
    }

    @Test("Normal Google Docs shortcuts are allowed")
    func normalGoogleDocsShortcutsAreAllowed() {
        var state = BrowserKeypressSafetyState()
        let decision = BrowserKeypressSafety.evaluate(
            key: "f",
            modifiers: ["command"],
            currentURL: "https://docs.google.com/document/d/example/edit",
            isGoogleWorkspaceEditor: true,
            state: &state
        )

        #expect(decision.allowed)
    }

    @Test("Run guard hard-stops after excessive bridge calls")
    func runGuardHardStopsAfterExcessiveBridgeCalls() {
        var guardrail = BrowserRunGuard(warningThreshold: 2, hardStopThreshold: 3)
        var decision = BrowserRunGuardDecision(shouldStop: false, warning: nil, diagnostics: [:])

        for _ in 0..<4 {
            decision = guardrail.record(
                path: "GET /snapshot",
                currentURL: "https://drive.google.com/drive/home",
                currentTitle: "Google Drive",
                pageType: "googleDrive"
            )
        }

        #expect(decision.shouldStop)
        #expect(guardrail.totalBrowserCalls == 4)
    }
}

