import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Control Safety")
struct BrowserControlSafetyTests {
    @Test("Text entry preflight blocks credential and MFA targets")
    func textEntryPreflightBlocksCredentialAndMFATargets() throws {
        let passwordBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "input[type=password]",
                "label": "Password",
                "role": "textbox",
                "tag": "input",
                "type": "password",
                "placeholder": "Password"
            ]
        ))
        #expect(passwordBlock["ok"] as? Bool == false)
        #expect(passwordBlock["error"] as? String == "credential_input_blocked")

        let mfaBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.insertText.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "#otp",
                "label": "Verification code",
                "role": "textbox",
                "tag": "input",
                "type": "text",
                "placeholder": "One-time code"
            ]
        ))
        #expect(mfaBlock["ok"] as? Bool == false)
        #expect(mfaBlock["error"] as? String == "mfa_input_blocked")

        let disabledPasswordBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": false,
                "selector": "#current-password",
                "label": "Current password",
                "role": "textbox",
                "tag": "input",
                "type": "password",
                "placeholder": "Password",
                "reason": "target_not_visible"
            ]
        ))
        #expect(disabledPasswordBlock["ok"] as? Bool == false)
        #expect(disabledPasswordBlock["error"] as? String == "credential_input_blocked")

        #expect(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.setValue.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "input[name=email]",
                "label": "Email",
                "role": "textbox",
                "tag": "input",
                "type": "email",
                "placeholder": "name@example.com"
            ]
        ) == nil)
    }

    @Test("Text entry preflight classifies requested selectors and autocomplete metadata")
    func textEntryPreflightClassifiesRequestedSelectorsAndAutocompleteMetadata() throws {
        let requestedSelectorBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.insertText.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "input",
                "requestedSelector": "input[autocomplete='one-time-code']",
                "label": "Code",
                "role": "textbox",
                "tag": "input",
                "type": "text",
                "autocomplete": "one-time-code"
            ]
        ))
        #expect(requestedSelectorBlock["error"] as? String == "mfa_input_blocked")

        let autocompleteBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "input",
                "label": "Account",
                "role": "textbox",
                "tag": "input",
                "type": "text",
                "autocomplete": "current-password"
            ]
        ))
        #expect(autocompleteBlock["error"] as? String == "credential_input_blocked")

        let nameBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "input",
                "label": "Account",
                "name": "current-password",
                "role": "textbox",
                "tag": "input",
                "type": "text"
            ]
        ))
        #expect(nameBlock["error"] as? String == "credential_input_blocked")
    }

    @Test("Text entry preflight redacts sensitive target attachments")
    func textEntryPreflightRedactsSensitiveTargetAttachments() throws {
        let block = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "#password",
                "requestedSelector": "input[type=password]",
                "label": "correct horse battery staple",
                "role": "textbox",
                "tag": "input",
                "type": "password",
                "placeholder": "enter your secret",
                "testID": "login-password",
                "href": "https://example.com/reset-password",
                "url": "https://example.com/login",
                "framePath": [
                    "https://auth.example.com/challenge?reset_token=secret-token",
                    "Verification code frame"
                ],
                "value": "raw-secret"
            ]
        ))
        let target = try #require(block["target"] as? [String: Any])
        #expect(target["href"] as? String == "https://example.com/reset-password")
        #expect(target["requestedSelector"] as? String == "input[type=password]")
        #expect(target["autocomplete"] as? String == "")
        #expect(target["label"] as? String == "[redacted]")
        #expect(target["placeholder"] as? String == "[redacted]")
        #expect(target["value"] == nil)
        #expect(target["framePath"] as? [String] == [
            "https://auth.example.com",
            "[redacted frame]"
        ])
        #expect(BrowserTextEntryPreflight.redactedTargetAttachment(for: block)["value"] == nil)
    }

    @Test("Text entry block responses are terminal for browser batches")
    func textEntryBlockResponsesAreTerminalForBrowserBatches() {
        #expect(BrowserTextEntryPreflight.isTerminalBlockResponse([
            "ok": false,
            "error": "credential_input_blocked"
        ]))
        #expect(BrowserTextEntryPreflight.isTerminalBlockResponse([
            "ok": false,
            "error": "mfa_input_blocked"
        ]))
        #expect(!BrowserTextEntryPreflight.isTerminalBlockResponse([
            "ok": false,
            "error": "target_not_visible"
        ]))
    }

    @Test("Focused text entry target script inspects shadow roots and frames")
    func focusedTextEntryTargetScriptInspectsShadowRootsAndFrames() {
        let script = BrowserAutomationScripts.focusedTargetInfoScript()
        #expect(script.contains("shadowRoot"))
        #expect(script.contains("activeElement"))
        #expect(script.contains("contentDocument"))
        #expect(script.contains("focused_frame_uninspectable"))
        #expect(script.contains("autocomplete"))
        #expect(script.contains("name: nameFor(el)"))
        #expect(script.contains("ownerDocument"))
    }

    @Test("Text mutation scripts revalidate sensitive focused and replacement targets")
    func textMutationScriptsRevalidateSensitiveTargets() {
        let insertScript = BrowserAutomationScripts.insertTextScript("secret")
        #expect(insertScript.contains("credential_input_blocked"))
        #expect(insertScript.contains("mfa_input_blocked"))
        #expect(insertScript.contains("autocomplete"))
        #expect(insertScript.contains("nameFor(target)"))

        let replaceTargetsScript = BrowserAutomationScripts.replaceTextTargetsInfoScript(selector: "input")
        #expect(replaceTargetsScript.contains("querySelectorAll(selector)"))
        #expect(replaceTargetsScript.contains("targets"))
        #expect(replaceTargetsScript.contains("name: nameFor(el)"))

        let replaceScript = BrowserAutomationScripts.replaceTextScript(
            find: "old",
            replacement: "new",
            selector: "input",
            all: true
        )
        #expect(replaceScript.contains("sensitiveBlock(el, \"setValue\")"))
        #expect(replaceScript.contains("return JSON.stringify(blocked)"))
    }

    @Test("Drive open default timeout covers slow Google Drive search results")
    func driveOpenDefaultTimeoutCoversSlowGoogleDriveSearchResults() {
        #expect(GoogleWorkspaceBrowserService.googleDriveOpenDefaultTimeoutSeconds >= 20)
        #expect(
            GoogleWorkspaceBrowserService.googleDriveOpenMaximumTimeoutSeconds
                >= GoogleWorkspaceBrowserService.googleDriveOpenDefaultTimeoutSeconds
        )
    }

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

    @Test("Google Docs full-document clipboard requires controlled when auto-promote is disabled")
    func googleDocsFullDocumentClipboardRequiresControlledWhenAutoPromoteDisabled() {
        #expect(GoogleWorkspaceBrowserService.googleDocsFullDocumentClipboardRequiresControlled(
            engine: .embedded,
            autoPromoteGoogleWorkspace: false
        ))
        #expect(!GoogleWorkspaceBrowserService.googleDocsFullDocumentClipboardRequiresControlled(
            engine: .embedded,
            autoPromoteGoogleWorkspace: true
        ))
        #expect(!GoogleWorkspaceBrowserService.googleDocsFullDocumentClipboardRequiresControlled(
            engine: .controlled,
            autoPromoteGoogleWorkspace: false
        ))
    }

    @Test("Drive open verifier rejects wrong Google editor title")
    func driveOpenVerifierRejectsWrongGoogleEditorTitle() {
        let opened = GoogleWorkspaceBrowserService.isOpenedDriveTarget(
            urlString: "https://docs.google.com/presentation/d/abc/edit",
            title: "Death Data Integration - Google Slides",
            name: "Alvaro1 t",
            startURL: "https://drive.google.com/drive/search?q=Alvaro1%20t"
        )

        #expect(opened == false)
    }

    @Test("Drive open verifier accepts matching Google editor title")
    func driveOpenVerifierAcceptsMatchingGoogleEditorTitle() {
        let opened = GoogleWorkspaceBrowserService.isOpenedDriveTarget(
            urlString: "https://docs.google.com/document/d/abc/edit",
            title: "Alvaro1 t - Google Docs",
            name: "Alvaro1 t",
            startURL: "https://drive.google.com/drive/search?q=Alvaro1%20t"
        )

        #expect(opened == true)
    }

    @Test("Drive open candidates ignore query-only controls")
    func driveOpenCandidatesIgnoreQueryOnlyControls() {
        let candidates = GoogleWorkspaceBrowserService.googleDriveOpenCandidates(
            controls: [
                [
                    "label": "Advanced search",
                    "name": "Advanced search",
                    "value": "Alvaro1 t",
                    "role": "row",
                    "tag": "tr",
                    "selector": "tbody > tr:nth-of-type(3)",
                    "bounds": ["centerX": 444, "centerY": 615]
                ],
                [
                    "label": "Alvaro1 t Google Docs Located in My Drive More info (Option + Right)",
                    "name": "Alvaro1 t Google Docs Located in My Drive More info (Option + Right)",
                    "role": "row",
                    "tag": "tr",
                    "selector": "tbody > tr:nth-of-type(4)",
                    "bounds": ["centerX": 444, "centerY": 670]
                ],
                [
                    "label": "Alvaro1 t Advanced search",
                    "name": "Alvaro1 t Advanced search",
                    "role": "option",
                    "tag": "tr",
                    "selector": "tbody > tr:nth-of-type(5)",
                    "bounds": ["centerX": 444, "centerY": 720]
                ]
            ],
            name: "Alvaro1 t",
            pageURL: "https://drive.google.com/drive/search?q=Alvaro1%20t"
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?["label"] as? String == "Alvaro1 t Google Docs Located in My Drive More info (Option + Right)")
    }

    @Test("Drive open candidates accept exact Drive file controls")
    func driveOpenCandidatesAcceptExactDriveFileControls() {
        let candidates = GoogleWorkspaceBrowserService.googleDriveOpenCandidates(
            controls: [
                [
                    "label": "Alvaro1 t",
                    "name": "Alvaro1 t",
                    "role": "button",
                    "tag": "div",
                    "type": "button",
                    "selector": "div[role='button'][aria-label='Alvaro1 t']",
                    "bounds": ["centerX": 311, "centerY": 129]
                ],
                [
                    "label": "Search in Drive",
                    "name": "Search in Drive",
                    "value": "Alvaro1 t",
                    "role": "textbox",
                    "tag": "input",
                    "selector": "input[aria-label='Search in Drive']",
                    "bounds": ["centerX": 421, "centerY": 83]
                ]
            ],
            name: "Alvaro1 t",
            pageURL: "https://drive.google.com/drive/search?q=Alvaro1%20t"
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?["selector"] as? String == "div[role='button'][aria-label='Alvaro1 t']")
    }

    @Test("Drive open candidates accept search rows with modified time metadata")
    func driveOpenCandidatesAcceptSearchRowsWithModifiedTimeMetadata() {
        let candidates = GoogleWorkspaceBrowserService.googleDriveOpenCandidates(
            controls: [
                [
                    "label": "Alvaro1 t 12:48 PM More actions (Alt+A)",
                    "name": "Alvaro1 t 12:48 PM More actions (Alt+A)",
                    "role": "row",
                    "tag": "tr",
                    "selector": "tbody > tr:nth-of-type(1)",
                    "bounds": ["centerX": 601, "centerY": 298]
                ],
                [
                    "label": "Alvaro1 test 12:48 PM More actions (Alt+A)",
                    "name": "Alvaro1 test 12:48 PM More actions (Alt+A)",
                    "role": "row",
                    "tag": "tr",
                    "selector": "tbody > tr:nth-of-type(2)",
                    "bounds": ["centerX": 601, "centerY": 346]
                ]
            ],
            name: "Alvaro1 t",
            pageURL: "https://drive.google.com/drive/search?q=Alvaro1%20t"
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?["label"] as? String == "Alvaro1 t 12:48 PM More actions (Alt+A)")
    }

    @Test("Drive open candidates accept rows with owner and location metadata")
    func driveOpenCandidatesAcceptRowsWithOwnerAndLocationMetadata() {
        let candidates = GoogleWorkspaceBrowserService.googleDriveOpenCandidates(
            controls: [
                [
                    "label": "Alvaro1 t 12:48 PM Me My Drive Google Docs More actions",
                    "name": "Alvaro1 t 12:48 PM Me My Drive Google Docs More actions",
                    "role": "row",
                    "tag": "tr",
                    "selector": "tbody > tr:nth-of-type(1)",
                    "bounds": ["centerX": 965, "centerY": 247]
                ]
            ],
            name: "Alvaro1 t",
            pageURL: "https://drive.google.com/drive/search"
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?["label"] as? String == "Alvaro1 t 12:48 PM Me My Drive Google Docs More actions")
    }

    @Test("Drive search URL encodes the requested file name")
    func driveSearchURLEncodesRequestedFileName() throws {
        let url = GoogleWorkspaceBrowserService.googleDriveSearchURL(for: "Alvaro1 t")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "https")
        #expect(components.host == "drive.google.com")
        #expect(components.path == "/drive/search")
        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "Alvaro1 t")
    }

    @Test("Google Docs verification query trims explicit text and truncates fallback")
    func googleDocsVerificationQueryTrimsExplicitTextAndTruncatesFallback() {
        #expect(GoogleWorkspaceBrowserService.googleDocsVerificationQuery(explicit: "  exact match  ", text: "ignored") == "exact match")
        #expect(GoogleWorkspaceBrowserService.googleDocsVerificationQuery(explicit: nil, text: "  alpha\n beta\tgamma  ") == "alpha beta gamma")

        let longText = String(repeating: "word ", count: 30)
        #expect(GoogleWorkspaceBrowserService.googleDocsVerificationQuery(explicit: nil, text: longText)?.count == 80)
    }

    @Test("Click-control exact matching rejects unrelated Outlook controls")
    @MainActor
    func clickControlExactMatchingRejectsUnrelatedOutlookControls() {
        let replyAll = [
            "label": "Reply all",
            "name": "Reply all",
            "role": "button",
            "selector": "button[aria-label='Reply all']"
        ]

        #expect(!ShelfBrowserSession.controlLabelStronglyMatches(replyAll, requestedLabel: "Other"))
        #expect(ShelfBrowserSession.controlLabelStronglyMatches(replyAll, requestedLabel: "Reply all"))
    }

    @Test("Mail mutation controls require confirmation")
    @MainActor
    func mailMutationControlsRequireConfirmation() {
        #expect(ShelfBrowserSession.mailMutationControlAction([
            "label": "Reply all",
            "role": "button"
        ]) == "reply all")
        #expect(ShelfBrowserSession.mailMutationControlAction([
            "label": "Other",
            "role": "tab"
        ]) == nil)
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

    @Test("Run guard hard-stops repeated Drive open helper failures")
    func runGuardHardStopsRepeatedDriveOpenFailures() {
        var guardrail = BrowserRunGuard(warningThreshold: 30, hardStopThreshold: 60)
        let url = "https://drive.google.com/drive/search"

        _ = guardrail.record(
            path: "POST /googleDriveOpen",
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )
        var decision = guardrail.recordOutcome(
            path: "POST /googleDriveOpen",
            response: ["ok": false, "error": "drive_file_not_opened"],
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )
        #expect(!decision.shouldStop)

        _ = guardrail.record(
            path: "POST /googleDriveOpen",
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )
        decision = guardrail.recordOutcome(
            path: "POST /googleDriveOpen",
            response: ["ok": false, "error": "drive_file_not_opened"],
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )

        #expect(decision.shouldStop)
        #expect(decision.warning?.contains("Google Drive open helper failed") == true)
        #expect(decision.diagnostics["lastError"] as? String == "drive_file_not_opened")
        #expect(decision.diagnostics["lastErrorRepeatCount"] as? Int == 2)
    }

    @Test("Run guard hard-stops no-progress Drive probing after helper failure")
    func runGuardHardStopsNoProgressDriveProbingAfterHelperFailure() {
        var guardrail = BrowserRunGuard(warningThreshold: 30, hardStopThreshold: 60)
        let url = "https://drive.google.com/drive/search"

        _ = guardrail.record(
            path: "POST /googleDriveOpen",
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )
        _ = guardrail.recordOutcome(
            path: "POST /googleDriveOpen",
            response: ["ok": false, "error": "drive_file_not_opened"],
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive",
            urlChanged: true
        )

        _ = guardrail.record(
            path: "POST /doubleClick",
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )
        var decision = guardrail.recordOutcome(
            path: "POST /doubleClick",
            response: ["ok": false, "error": "unsupported_action"],
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive",
            urlChanged: false
        )
        #expect(!decision.shouldStop)

        _ = guardrail.record(
            path: "POST /open",
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive"
        )
        decision = guardrail.recordOutcome(
            path: "POST /open",
            response: ["ok": false, "error": "unsupported_action"],
            currentURL: url,
            currentTitle: "Search results - Google Drive",
            pageType: "googleDrive",
            urlChanged: false
        )

        #expect(decision.shouldStop)
        #expect(decision.warning?.contains("generic Drive actions are not changing page state") == true)
        #expect(decision.diagnostics["drivePostFailureGenericNoProgressMutations"] as? Int == 2)
    }

    @Test("Browser action metadata classifies read-only and mutating actions")
    func browserActionMetadataClassifiesActions() {
        let actions = BrowserBridgeActionMetadata.enriched([
            ["method": "GET", "path": "/health"],
            ["method": "POST", "path": "/googleDocsReplaceDocument"],
            ["method": "POST", "path": "/click"]
        ])

        #expect(actions[0]["category"] as? String == "status")
        #expect(actions[0]["riskLevel"] as? String == "read-only")
        #expect(actions[0]["confirmation"] as? String == "not-required")
        #expect(actions[0]["preferredUse"] as? String != nil)
        #expect(actions[1]["category"] as? String == "site-mutation")
        #expect(actions[1]["riskLevel"] as? String == "high-impact")
        #expect(actions[2]["category"] as? String == "mutation")
        #expect(actions[2]["confirmation"] as? String == "required-for-dangerous-targets")
    }

    @Test("Browser recovery hints re-analyze stale controls with label context")
    func browserRecoveryHintsReanalyzeStaleControlsWithLabelContext() {
        let recovery = BrowserBridgeRecoveryHints.recoveryObject(
            error: "stale_analysis",
            action: "click",
            analysisID: "ana_1",
            controlID: "ctl_2",
            controlLabel: "Save",
            validActions: []
        ) ?? [:]

        #expect(recovery["kind"] as? String == "reanalyze")
        #expect(recovery["failedAction"] as? String == "click")
        #expect(recovery["nextCommand"] as? String == "astra-browser analyze --query 'Save'")
    }

    @Test("Browser recovery hints choose a valid fallback action")
    func browserRecoveryHintsChooseValidFallbackAction() {
        let recovery = BrowserBridgeRecoveryHints.recoveryObject(
            error: "unsupported_action",
            action: "click",
            analysisID: "ana_1",
            controlID: "ctl_2",
            validActions: [BrowserActionKind.open.rawValue]
        ) ?? [:]

        #expect(recovery["kind"] as? String == "choose-supported-action")
        #expect(recovery["nextCommand"] as? String == "astra-browser open --analysis 'ana_1' --control 'ctl_2'")
    }

    @Test("Browser status summary reports readiness and last failures")
    func browserStatusSummaryReportsReadinessAndLastFailures() {
        let ready = BrowserBridgeStatusSummary.build(
            bridgeEnabled: true,
            hasEndpoint: true,
            backend: "controlled Chromium",
            controlledState: "running",
            controlledRunning: true,
            hasDebugPort: true,
            activeAdapterCount: 1,
            lastFailure: nil
        )
        let failing = BrowserBridgeStatusSummary.build(
            bridgeEnabled: true,
            hasEndpoint: true,
            backend: "controlled Chromium",
            controlledState: "running",
            controlledRunning: true,
            hasDebugPort: true,
            activeAdapterCount: 1,
            lastFailure: "stale_analysis"
        )
        let disabled = BrowserBridgeStatusSummary.build(
            bridgeEnabled: false,
            hasEndpoint: false,
            backend: "embedded WebKit",
            controlledState: "stopped",
            controlledRunning: false,
            hasDebugPort: false,
            activeAdapterCount: 0,
            lastFailure: "stale_analysis"
        )

        #expect(ready["readiness"] as? String == "ready")
        #expect(ready["debugPort"] as? String == "available")
        #expect(failing["readiness"] as? String == "needs_attention")
        #expect(failing["lastFailure"] as? String == "stale_analysis")
        #expect(disabled["readiness"] as? String == "disabled")
        #expect(disabled["bridge"] as? String == "disabled")
    }

    @Test("Browser recovery hints attach top-level next command")
    func browserRecoveryHintsAttachTopLevelNextCommand() {
        let failedAction = BrowserBridgeRecoveryHints.failedActionName(
            method: "POST",
            path: "/click"
        )
        var response: [String: Any] = [
            "ok": false,
            "error": "browser_action_budget_exceeded"
        ]

        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: "browser_action_budget_exceeded",
            action: failedAction
        )

        #expect(response["nextCommand"] as? String == "astra-browser trace")
        let recovery = response["recovery"] as? [String: Any]
        #expect(recovery?["kind"] as? String == "inspect-trace")
        #expect(recovery?["failedAction"] as? String == "POST /click")
    }
}
