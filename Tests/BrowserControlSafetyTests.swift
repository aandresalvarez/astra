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

        let tokenBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "input[name='access_token']",
                "label": "API key",
                "name": "access_token",
                "role": "textbox",
                "tag": "input",
                "type": "text",
                "placeholder": "Personal access token"
            ]
        ))
        #expect(tokenBlock["error"] as? String == "credential_input_blocked")
    }

    @Test("Secret revealing controls remain high risk outside text fields")
    func secretRevealingControlsRemainHighRiskOutsideTextFields() throws {
        let showPasswordBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.click.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "button.show-password",
                "label": "Show password",
                "role": "button",
                "tag": "button",
                "type": "button"
            ]
        ))
        #expect(showPasswordBlock["error"] as? String == "credential_input_blocked")

        let copySecretBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.click.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "button[data-testid='copy-secret']",
                "label": "Copy secret",
                "role": "button",
                "tag": "button",
                "type": "button"
            ]
        ))
        #expect(copySecretBlock["error"] as? String == "credential_input_blocked")

        #expect(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.open.rawValue,
            targetInfo: [
                "ok": true,
                "selector": "a[href='/reset-password']",
                "label": "Forgot password?",
                "role": "link",
                "tag": "a",
                "href": "https://example.com/reset-password"
            ]
        ) == nil)
    }

    @Test("Uninspectable focused frames block raw text entry")
    func uninspectableFocusedFramesBlockRawTextEntry() throws {
        let neutralFrameBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.insertText.rawValue,
            targetInfo: [
                "ok": false,
                "error": "focused_frame_uninspectable",
                "selector": "iframe",
                "label": "Comments editor",
                "role": "",
                "tag": "iframe",
                "framePath": ["https://docs.example.com/editor"],
                "frameFocusUninspectable": true
            ]
        ))
        #expect(neutralFrameBlock["error"] as? String == "focused_frame_uninspectable")
        #expect(BrowserTextEntryPreflight.isTerminalBlockResponse(neutralFrameBlock))

        let passwordFrameBlock = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.insertText.rawValue,
            targetInfo: [
                "ok": false,
                "error": "focused_frame_uninspectable",
                "selector": "iframe",
                "label": "Password challenge",
                "role": "",
                "tag": "iframe",
                "framePath": ["https://auth.example.com/current-password"],
                "frameFocusUninspectable": true
            ]
        ))
        #expect(passwordFrameBlock["error"] as? String == "focused_frame_uninspectable")
    }

    @Test("Text entry preflight redacts sensitive target attachments")
    func textEntryPreflightRedactsSensitiveTargetAttachments() throws {
        let block = try #require(BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.fill.rawValue,
            targetInfo: [
                "ok": true,
                "selector": #"input[aria-label="enter your secret"]"#,
                "requestedSelector": #"input[aria-label="verification code"]"#,
                "label": "correct horse battery staple",
                "role": "textbox",
                "tag": "input",
                "type": "password",
                "autocomplete": "current-password",
                "placeholder": "enter your secret",
                "testID": "login-password",
                "href": "https://example.com/reset-password?token=secret-token#secret",
                "url": "https://example.com/login?session=secret-token#secret",
                "framePath": [
                    "https://auth.example.com/challenge?reset_token=secret-token",
                    "Verification code frame"
                ],
                "value": "raw-secret"
            ]
        ))
        let target = try #require(block["target"] as? [String: Any])
        #expect(target["href"] as? String == "https://example.com")
        #expect(target["url"] as? String == "https://example.com")
        #expect(target["selector"] as? String == "input[redacted-selector]")
        #expect(target["requestedSelector"] as? String == "input[redacted-selector]")
        #expect(target["autocomplete"] as? String == "[redacted]")
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
        #expect(BrowserTextEntryPreflight.isTerminalBlockResponse([
            "ok": false,
            "stopReason": "credential_input_blocked",
            "results": []
        ]))
        #expect(BrowserTextEntryPreflight.terminalStopReason(for: [
            "ok": false,
            "stopReason": "credential_input_blocked",
            "results": []
        ]) == "credential_input_blocked")
        let stopped = BrowserTextEntryPreflight.stoppedResponse(results: [[
            "ok": false,
            "action": "set",
            "error": "credential_input_blocked"
        ]])
        #expect(stopped["ok"] as? Bool == false)
        #expect(stopped["stopReason"] as? String == "credential_input_blocked")
        #expect(!BrowserTextEntryPreflight.isTerminalBlockResponse([
            "ok": false,
            "error": "target_not_visible"
        ]))
    }

    @Test("JSON decoded text entry block responses are terminal for browser batches")
    func jsonDecodedTextEntryBlockResponsesAreTerminalForBrowserBatches() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": false,
            "stopReason": "text_entry_target_changed",
            "results": []
        ])
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(BrowserTextEntryPreflight.isTerminalBlockResponse(response))
        #expect(BrowserTextEntryPreflight.terminalStopReason(for: response) == "text_entry_target_changed")
        #expect(!BrowserTextEntryPreflight.isTerminalBlockResponse([
            "stopReason": "text_entry_target_changed",
            "results": []
        ]))
    }

    @Test("Focused text entry target script inspects shadow roots and frames")
    func focusedTextEntryTargetScriptInspectsShadowRootsAndFrames() throws {
        let script = BrowserAutomationScripts.focusedTargetInfoScript()
        #expect(script.contains("shadowRoot"))
        #expect(script.contains("activeElement"))
        #expect(script.contains("contentDocument"))
        #expect(script.contains("focused_frame_uninspectable"))
        #expect(script.contains("autocomplete"))
        #expect(script.contains("name: nameFor(el)"))
        #expect(script.contains("ownerDocument"))
        #expect(script.contains("targetSignature: targetSignatureFor(el, target.framePath || [], target.shadowDepth || 0)"))
        #expect(script.contains(#"url.search = "";"#))
        #expect(script.contains(#"url.hash = "";"#))
        #expect(script.contains("locator: target.locator || locatorSummary()"))
        #expect(script.contains(#"locator: { focused: true }"#))
        #expect(script.contains("const focusedTextEntryEligible"))
        #expect(script.contains(#"type === "hidden""#))
        #expect(script.contains("!visible(target.el) && !focusedTextEntryEligible(target.el)"))
        let preserveFailure = try #require(script.range(of: "if (target.ok === false) return JSON.stringify(publicTarget(target));"))
        let successReturn = try #require(script.range(of: "return JSON.stringify(publicTarget(Object.assign({}, target, { ok: true })));"))
        #expect(preserveFailure.lowerBound < successReturn.lowerBound)
    }

    @Test("Text mutation scripts revalidate sensitive focused and replacement targets")
    func textMutationScriptsRevalidateSensitiveTargets() throws {
        let typeScript = BrowserAutomationScripts.typeScript(
            selector: "input[name=email]",
            text: "secret",
            clear: true
        )
        #expect(typeScript.contains("credential_input_blocked"))
        #expect(typeScript.contains("mfa_input_blocked"))
        #expect(typeScript.contains("const astraSensitiveRisk"))
        #expect(typeScript.contains("const astraSensitiveBlock"))
        #expect(typeScript.contains("const blocked = astraSensitiveBlock(el, action, selector || \"\""))
        #expect(typeScript.contains("if (blocked) return JSON.stringify(blocked)"))
        #expect(!typeScript.contains("const sensitiveRisk"))

        let insertScript = BrowserAutomationScripts.insertTextScript("secret")
        #expect(insertScript.contains("credential_input_blocked"))
        #expect(insertScript.contains("mfa_input_blocked"))
        #expect(insertScript.contains("autocomplete"))
        #expect(insertScript.contains("name: helpers.nameFor(el)"))
        #expect(insertScript.contains("astraSensitiveBlock(target, \"insertText\""))
        #expect(insertScript.contains("const isEditableTextEntry = lowerTag === \"input\""))
        #expect(insertScript.contains("api key|apikey|api_key|token|access token|access_token"))
        #expect(insertScript.contains("href: astraSensitiveURL(metadata.href)"))
        #expect(insertScript.contains("url: astraSensitiveURL(location.href)"))

        let replaceTargetsScript = BrowserAutomationScripts.replaceTextTargetsInfoScript(selector: "input", find: "old", all: false)
        #expect(replaceTargetsScript.contains("querySelectorAll(selector)"))
        #expect(replaceTargetsScript.contains("const find = \"old\""))
        #expect(replaceTargetsScript.contains("const replaceAll = false"))
        #expect(replaceTargetsScript.contains("replaceWouldMutate"))
        #expect(replaceTargetsScript.contains("mutationTargetCount"))
        #expect(replaceTargetsScript.contains("const scopedMutationTargets = replaceAll ? mutationTargets : mutationTargets.slice(0, 1)"))
        #expect(replaceTargetsScript.contains("targets"))
        #expect(replaceTargetsScript.contains("name: nameFor(el)"))

        let replaceScript = BrowserAutomationScripts.replaceTextScript(
            find: "old",
            replacement: "new",
            selector: "input",
            all: true
        )
        #expect(replaceScript.contains("astraSensitiveBlock(el, \"setValue\", selector || \"\""))
        #expect(replaceScript.contains("return JSON.stringify(blocked)"))
        #expect(replaceScript.contains("const editable = (el) => \"value\" in el || el.isContentEditable || el.tagName === \"TEXTAREA\""))
        #expect(replaceScript.contains("if (!visible(el) || !editable(el)) continue"))
        #expect(replaceScript.contains("autocomplete: \"[redacted]\""))
        #expect(replaceScript.contains("href: astraSensitiveURL(metadata.href)"))
        #expect(replaceScript.contains("url: astraSensitiveURL(location.href)"))
        let replacementCheck = try #require(replaceScript.range(of: "const result = replaceInString(before);"))
        let sensitiveCheck = try #require(replaceScript.range(of: "const blocked = astraSensitiveBlock(el, \"setValue\""))
        #expect(replacementCheck.lowerBound < sensitiveCheck.lowerBound)

        let selectorlessReplaceScript = BrowserAutomationScripts.replaceTextScript(
            find: "old",
            replacement: "new",
            selector: nil,
            all: true
        )
        #expect(selectorlessReplaceScript.contains("const selector = null"))
        #expect(selectorlessReplaceScript.contains("querySelectorAll(\"input, textarea, [contenteditable]:not([contenteditable=false])\")"))
        #expect(!selectorlessReplaceScript.contains("querySelectorAll(\"input, textarea, [contenteditable]\")"))
    }

    @Test("Google editor replacement preflight preserves find-replace hint")
    func googleEditorReplacementPreflightPreservesFindReplaceHint() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let preflightPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSessionTextEntryPreflight.swift")
            .path
        let source = try String(contentsOfFile: preflightPath, encoding: .utf8)

        #expect(source.contains("GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(currentURL)"))
        #expect(source.contains("BrowserFlightPageSnapshot.redactedURLString(currentURL)"))
        #expect(source.contains(#""url": redactedCurrentURL"#))
        #expect(source.contains(#""editor_surface_requires_find_replace""#))
        #expect(source.contains("Google editor canvas text is not directly editable through DOM replacement."))
    }

    @Test("Selectorless replace loop hints use the searched text as fallback target")
    func selectorlessReplaceLoopHintsUseFindFallbackTarget() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sessionPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSession.swift")
            .path
        let source = try String(contentsOfFile: sessionPath, encoding: .utf8)

        #expect(source.contains(#"annotateBrowserLoopHint(json: json, action: "replaceText", target: resolvedSelector ?? find)"#))
        #expect(!source.contains(#"annotateBrowserLoopHint(json: json, action: "replaceText", target: resolvedSelector ?? "")"#))
    }

    @Test("Selectorless replace inspects the same editable targets it can mutate")
    func selectorlessReplacePreflightsDefaultEditableTargets() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sessionPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSession.swift")
            .path
        let source = try String(contentsOfFile: sessionPath, encoding: .utf8)

        #expect(source.contains("resolvedSelector ?? BrowserAutomationScripts.defaultEditableSelector"))
        #expect(!source.contains("if let resolvedSelector, let blocked = try await blockedReplacementTextEntryResult"))
    }

    @Test("Selectorless replace preflight does not report unreachable missing selector errors")
    func selectorlessReplacePreflightDoesNotReportUnreachableMissingSelectorErrors() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let preflightPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSessionTextEntryPreflight.swift")
            .path
        let source = try String(contentsOfFile: preflightPath, encoding: .utf8)
        let methodStart = try #require(source.range(of: "func blockedReplacementTextEntryResult(find: String, selector: String, all: Bool) async throws -> [String: Any]? {"))
        let methodEnd = try #require(source[methodStart.upperBound...].range(of: "private enum BrowserTextEntryPreflightJSON"))
        let methodSource = source[methodStart.lowerBound..<methodEnd.lowerBound]

        #expect(!methodSource.contains(#""text_entry_target_required""#))
        #expect(!methodSource.contains("guard !selector.isEmpty"))
        #expect(methodSource.contains(#"action: "replaceText""#))
        #expect(!methodSource.contains("action: BrowserActionKind.setValue.rawValue"))
    }

    @Test("Controlled text entry binds CDP dispatch to the preflighted focused target")
    func controlledTextEntryBindsCDPDispatchToPreflightedFocusedTarget() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sessionPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSession.swift")
            .path
        let controllerPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ControlledBrowserController.swift")
            .path
        let controlledPreflightPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ControlledBrowserTextEntryPreflight.swift")
            .path
        let sessionSource = try String(contentsOfFile: sessionPath, encoding: .utf8)
        let controllerSource = try String(contentsOfFile: controllerPath, encoding: .utf8)
        let controlledPreflightSource = try String(contentsOfFile: controlledPreflightPath, encoding: .utf8)

        #expect(sessionSource.contains("controlledBrowser.keypress("))
        #expect(sessionSource.contains("controlledBrowser.insertText("))
        #expect(sessionSource.contains("expectedFocusedTargetSignature: preflight.targetSignature"))
        #expect(sessionSource.contains("BrowserAutomationScripts.keypressScript("))
        #expect(sessionSource.contains("BrowserAutomationScripts.insertTextScript("))
        #expect(sessionSource.contains("expectedFocusedTargetSignature: preflight.targetSignature"))
        #expect(sessionSource.contains("allowUnboundFocusedTargetDispatch: preflight.allowUnboundFocusedTargetDispatch"))
        let embeddedScript = BrowserAutomationScripts.keypressScript(
            key: "x",
            modifiers: [],
            expectedFocusedTargetSignature: "expected-signature"
        )
        #expect(embeddedScript.contains("if (expectedFocusedTargetSignature)"))
        #expect(embeddedScript.contains("text_entry_target_changed"))
        #expect(embeddedScript.contains(#"autocomplete: "[redacted]""#))
        #expect(embeddedScript.contains("const target = activeTarget.el || document.body"))
        let embeddedUnboundActivationScript = BrowserAutomationScripts.keypressScript(
            key: "Space",
            modifiers: [],
            expectedFocusedTargetSignature: nil,
            allowUnboundFocusedTargetDispatch: true
        )
        #expect(embeddedUnboundActivationScript.contains("const allowUnboundFocusedTargetDispatch = true"))
        #expect(embeddedUnboundActivationScript.contains("else if (allowUnboundFocusedTargetDispatch && activeTarget.el)"))
        let embeddedInsertScript = BrowserAutomationScripts.insertTextScript(
            "secret",
            expectedFocusedTargetSignature: "expected-signature"
        )
        #expect(embeddedInsertScript.contains("const expectedFocusedTargetSignature = \"expected-signature\""))
        #expect(embeddedInsertScript.contains("const activeTarget = deepActiveElement(document, [], 0)"))
        #expect(embeddedInsertScript.contains("const targetInfo = publicTarget(activeTarget)"))
        #expect(embeddedInsertScript.contains("targetInfo.targetSignature !== expectedFocusedTargetSignature"))
        #expect(embeddedInsertScript.contains("framePath: Array.isArray(targetInfo.framePath) ? targetInfo.framePath.map(() => \"[redacted frame]\") : []"))
        #expect(embeddedInsertScript.contains("text_entry_target_changed"))
        #expect(embeddedInsertScript.contains(#"autocomplete: "[redacted]""#))
        #expect(embeddedInsertScript.contains(#"action: "insertText""#))
        #expect(controllerSource.contains("allowUnboundFocusedTargetDispatch: allowUnboundFocusedTargetDispatch"))
        #expect(controllerSource.contains("validateFocusedTextEntryTarget(action: \"insertText\", expectedSignature: expectedFocusedTargetSignature, client: client)"))
        #expect(controlledPreflightSource.contains("BrowserTextEntryPreflight.targetSignature(for: targetInfo) != nil"))

        let keypressStart = try #require(controllerSource.range(of: "func keypress("))
        let keypressEnd = try #require(controllerSource[keypressStart.upperBound...].range(of: "func insertText"))
        let keypressSource = controllerSource[keypressStart.lowerBound..<keypressEnd.lowerBound]
        let keypressValidation = try #require(keypressSource.range(of: "validateFocusedTextEntryTarget"))
        let keypressDispatch = try #require(keypressSource.range(of: #""Input.dispatchKeyEvent""#))
        #expect(keypressValidation.lowerBound < keypressDispatch.lowerBound)

        let insertStart = try #require(controllerSource.range(of: "func insertText(_ text: String, expectedFocusedTargetSignature: String?) async throws -> String {"))
        let insertEnd = try #require(controllerSource[insertStart.upperBound...].range(of: "func showWindow"))
        let insertSource = controllerSource[insertStart.lowerBound..<insertEnd.lowerBound]
        let insertValidation = try #require(insertSource.range(of: "validateFocusedTextEntryTarget"))
        let insertDispatch = try #require(insertSource.range(of: #""Input.insertText""#))
        #expect(insertValidation.lowerBound < insertDispatch.lowerBound)
    }

    @Test("Focused target signatures ignore failed probes and URL query fragments")
    func focusedTargetSignaturesIgnoreFailedProbesAndURLQueryFragments() throws {
        #expect(BrowserTextEntryPreflight.targetSignature(for: [
            "ok": false,
            "targetSignature": "should-not-bind"
        ]) == nil)

        let signature = try #require(BrowserTextEntryPreflight.targetSignature(for: [
            "ok": true,
            "selector": "input[name=comment]",
            "tag": "input",
            "type": "text",
            "name": "comment",
            "role": "textbox",
            "autocomplete": "off",
            "framePath": [],
            "shadowDepth": 0,
            "url": "https://app.example.com/editor?token=secret#draft"
        ]))

        #expect(signature.hasSuffix("\u{1f}https://app.example.com/editor"))
        #expect(!signature.contains("token=secret"))
        #expect(!signature.contains("#draft"))
    }

    @Test("Keypress audit logs requested phase before focused text entry preflight")
    func keypressAuditLogsRequestedPhaseBeforeFocusedTextEntryPreflight() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sessionPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSession.swift")
            .path
        let source = try String(contentsOfFile: sessionPath, encoding: .utf8)
        let methodStart = try #require(source.range(of: "private func keypress("))
        let methodEnd = try #require(source[methodStart.upperBound...].range(of: "private func insertText"))
        let methodSource = source[methodStart.lowerBound..<methodEnd.lowerBound]

        let requestedLog = try #require(methodSource.range(of: #"phase: "requested""#))
        let preflightCheck = try #require(methodSource.range(of: "keypressTextEntryDispatchValidation"))
        #expect(requestedLog.lowerBound < preflightCheck.lowerBound)
    }

    @Test("Replacement target inspection refreshes controlled browser metadata")
    func replacementTargetInspectionRefreshesControlledBrowserMetadata() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controllerPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ControlledBrowserController.swift")
            .path
        let source = try String(contentsOfFile: controllerPath, encoding: .utf8)
        let methodStart = try #require(source.range(of: "func replaceTextTargetsInfo(selector: String, find: String, all: Bool) async throws -> String {"))
        let methodEnd = try #require(source[methodStart.upperBound...].range(of: "func keypress("))
        let methodSource = source[methodStart.lowerBound..<methodEnd.lowerBound]

        #expect(methodSource.contains("try await refreshPageMetadata()"))
        let evaluateCall = try #require(methodSource.range(of: "BrowserAutomationScripts.replaceTextTargetsInfoScript"))
        let metadataRefresh = try #require(methodSource.range(of: "try await refreshPageMetadata()"))
        let returnValue = try #require(methodSource.range(of: "return value"))
        #expect(evaluateCall.lowerBound < metadataRefresh.lowerBound)
        #expect(metadataRefresh.lowerBound < returnValue.lowerBound)
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

    @Test("Navigation keypresses do not require sensitive text entry preflight")
    func navigationKeypressesDoNotRequireSensitiveTextEntryPreflight() {
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "Escape", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "esc", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "Tab", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "ArrowLeft", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "left", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "right", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "up", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "down", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "Home", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "End", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "PageDown", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "PageUp", modifiers: []))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "l", modifiers: ["command"]))
    }

    @Test("Text-producing keypresses require sensitive text entry preflight")
    func textProducingKeypressesRequireSensitiveTextEntryPreflight() {
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "x", modifiers: []))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "aa", modifiers: []))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "Shift", modifiers: []))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "Space", modifiers: []))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "Backspace", modifiers: []))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "v", modifiers: ["command"]))
    }

    @Test("Page activation keys can dispatch without focused target only for unbound focus")
    func pageActivationKeysCanDispatchWithoutFocusedTargetOnlyForUnboundFocus() throws {
        let missingTarget = BrowserTextEntryPreflight.missingFocusedTargetBlockResponse(
            action: "keypress",
            targetInfo: [
                "ok": false,
                "error": "no_focused_element",
                "role": "document",
                "tag": "body",
                "url": "https://app.example.com/list"
            ]
        )
        let missingTargetJSON = try jsonString(missingTarget)
        let changedTargetJSON = try jsonString([
            "ok": false,
            "stopReason": "text_entry_target_changed",
            "error": "text_entry_target_changed"
        ])

        #expect(BrowserKeypressSafety.canDispatchWithoutFocusedTarget(key: "Space", modifiers: []))
        #expect(BrowserKeypressSafety.canDispatchWithoutFocusedTarget(key: "Enter", modifiers: []))
        #expect(!BrowserKeypressSafety.canDispatchWithoutFocusedTarget(key: "Backspace", modifiers: []))
        #expect(!BrowserKeypressSafety.canDispatchWithoutFocusedTarget(key: "Space", modifiers: ["command"]))
        #expect(BrowserKeypressSafety.canDispatchBlockedPreflightWithoutFocusedTarget(
            key: "Space",
            modifiers: [],
            blockedPreflightJSON: missingTargetJSON
        ))
        #expect(BrowserKeypressSafety.canDispatchBlockedPreflightWithoutFocusedTarget(
            key: "Return",
            modifiers: [],
            blockedPreflightJSON: missingTargetJSON
        ))
        #expect(!BrowserKeypressSafety.canDispatchBlockedPreflightWithoutFocusedTarget(
            key: "Backspace",
            modifiers: [],
            blockedPreflightJSON: missingTargetJSON
        ))
        #expect(!BrowserKeypressSafety.canDispatchBlockedPreflightWithoutFocusedTarget(
            key: "Space",
            modifiers: [],
            blockedPreflightJSON: changedTargetJSON
        ))
    }

    @Test("Keypress preflight only falls through unbound page activation blocks")
    func keypressPreflightOnlyFallsThroughUnboundPageActivationBlocks() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sessionPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSession.swift")
            .path
        let preflightPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSessionTextEntryPreflight.swift")
            .path
        let source = try String(contentsOfFile: sessionPath, encoding: .utf8)
        let preflightSource = try String(contentsOfFile: preflightPath, encoding: .utf8)
        let methodStart = try #require(source.range(of: "private func keypress("))
        let methodEnd = try #require(source[methodStart.upperBound...].range(of: "private func insertText"))
        let methodSource = source[methodStart.lowerBound..<methodEnd.lowerBound]
        let helperStart = try #require(preflightSource.range(of: "func keypressTextEntryDispatchValidation"))
        let helperEnd = try #require(preflightSource[helperStart.upperBound...].range(of: "func focusedTextEntryPreflight"))
        let helperSource = preflightSource[helperStart.lowerBound..<helperEnd.lowerBound]

        let blockedResult = try #require(helperSource.range(of: "guard let result = preflight.blockedResultJSON else"))
        let blockedSource = helperSource[blockedResult.lowerBound...]
        let fallthroughGuard = try #require(blockedSource.range(of: "BrowserKeypressSafety.canDispatchBlockedPreflightWithoutFocusedTarget"))
        let returnBlocked = try #require(blockedSource.range(of: "blockedResultJSON: result"))
        #expect(blockedResult.lowerBound < fallthroughGuard.lowerBound)
        #expect(fallthroughGuard.lowerBound < returnBlocked.lowerBound)
        #expect(helperSource.contains("allowUnboundFocusedTargetDispatch: true"))
        #expect(methodSource.contains("keypressTextEntryDispatchValidation"))
        #expect(methodSource.contains("if let result = preflight.blockedResultJSON { return result }"))
        #expect(methodSource.contains("expectedFocusedTargetSignature: preflight.targetSignature"))
        #expect(methodSource.contains("allowUnboundFocusedTargetDispatch: preflight.allowUnboundFocusedTargetDispatch"))
    }

    @Test("Uninspectable frame block redacts target metadata")
    func uninspectableFrameBlockRedactsTargetMetadata() throws {
        let blocked = try #require(BrowserTextEntryPreflight.blockResponse(
            action: "keypress",
            targetInfo: [
                "selector": "iframe[src='https://auth.example.com/challenge?token=secret']",
                "label": "https://auth.example.com/challenge?token=secret",
                "name": "secret-frame",
                "role": "frame",
                "tag": "iframe",
                "autocomplete": "one-time-code",
                "href": "https://auth.example.com/challenge?token=secret#otp",
                "url": "https://app.example.com/login?session=secret#frame",
                "framePath": ["https://auth.example.com/challenge?token=secret#otp"],
                "frameFocusUninspectable": true
            ]
        ))
        let target = try #require(blocked["target"] as? [String: Any])

        #expect(blocked["error"] as? String == "focused_frame_uninspectable")
        #expect(target["selector"] as? String == "iframe[redacted-selector]")
        #expect(target["label"] as? String == "[redacted]")
        #expect(target["name"] as? String == "[redacted]")
        #expect(target["autocomplete"] as? String == "[redacted]")
        #expect(target["href"] as? String == "https://auth.example.com")
        #expect(target["url"] as? String == "https://app.example.com")
        #expect(target["framePath"] as? [String] == ["https://auth.example.com"])
    }

    @Test("Target changed blocks force high impact redaction")
    func targetChangedBlocksForceHighImpactRedaction() throws {
        let blocked = BrowserTextEntryPreflight.focusChangedBlockResponse(
            action: "keypress",
            targetInfo: [
                "selector": "input[name='comment']",
                "requestedSelector": "input[name='comment']",
                "label": "Comment",
                "name": "comment",
                "role": "textbox",
                "tag": "input",
                "type": "text",
                "autocomplete": "off",
                "placeholder": "Comment",
                "href": "https://app.example.com/comment?token=secret#frag",
                "url": "https://app.example.com/editor?session=secret#frag",
                "framePath": ["https://frame.example.com/editor?token=secret#frag"]
            ]
        )
        let target = try #require(blocked["target"] as? [String: Any])

        #expect(blocked["error"] as? String == "text_entry_target_changed")
        #expect(blocked["risk"] as? String == BrowserRisk.unknownHighImpact.rawValue)
        #expect(target["selector"] as? String == "input[redacted-selector]")
        #expect(target["requestedSelector"] as? String == "input[redacted-selector]")
        #expect(target["label"] as? String == "[redacted]")
        #expect(target["name"] as? String == "[redacted]")
        #expect(target["autocomplete"] as? String == "[redacted]")
        #expect(target["placeholder"] as? String == "[redacted]")
        #expect(target["href"] as? String == "https://app.example.com")
        #expect(target["url"] as? String == "https://app.example.com")
        #expect(target["framePath"] as? [String] == ["https://frame.example.com"])
    }

    @Test("Missing focused target blocks text entry")
    func missingFocusedTargetBlocksTextEntry() throws {
        let blocked = BrowserTextEntryPreflight.missingFocusedTargetBlockResponse(
            action: "keypress",
            targetInfo: [
                "ok": false,
                "error": "no_focused_element",
                "selector": "body",
                "label": "Document",
                "name": "document",
                "role": "document",
                "tag": "body",
                "url": "https://app.example.com/editor?token=secret#draft"
            ]
        )
        let target = try #require(blocked["target"] as? [String: Any])

        #expect(blocked["error"] as? String == "text_entry_target_not_bound")
        #expect(blocked["risk"] as? String == BrowserRisk.unknownHighImpact.rawValue)
        #expect(BrowserTextEntryPreflight.isTerminalBlockResponse(blocked))
        #expect(BrowserTextEntryPreflight.terminalStopReason(for: blocked) == "text_entry_target_not_bound")
        #expect(target["label"] as? String == "[redacted]")
        #expect(target["url"] as? String == "https://app.example.com")
    }

    @Test("Focused target bind distinguishes missing focus from changed target")
    func focusedTargetBindDistinguishesMissingFocusFromChangedTarget() throws {
        let missingFocus = try #require(BrowserTextEntryPreflight.focusedTargetBindBlockResponse(
            action: "keypress",
            targetInfo: [
                "ok": false,
                "error": "no_focused_element",
                "selector": "body",
                "label": "Document",
                "role": "document",
                "tag": "body",
                "url": "https://app.example.com/editor?token=secret#draft"
            ],
            expectedSignature: "input\u{1f}input\u{1f}text"
        ))
        #expect(missingFocus["error"] as? String == "text_entry_target_not_bound")
        #expect(BrowserTextEntryPreflight.terminalStopReason(for: missingFocus) == "text_entry_target_not_bound")

        let changedTarget = try #require(BrowserTextEntryPreflight.focusedTargetBindBlockResponse(
            action: "keypress",
            targetInfo: [
                "ok": true,
                "selector": "textarea[name='comment']",
                "tag": "textarea",
                "type": "text",
                "name": "comment",
                "role": "textbox",
                "autocomplete": "off",
                "url": "https://app.example.com/editor"
            ],
            expectedSignature: "previous-target-signature"
        ))
        #expect(changedTarget["error"] as? String == "text_entry_target_changed")
        #expect(BrowserTextEntryPreflight.terminalStopReason(for: changedTarget) == "text_entry_target_changed")
    }

    @Test("Modified editing keypresses require sensitive text entry preflight")
    func modifiedEditingKeypressesRequireSensitiveTextEntryPreflight() {
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "Backspace", modifiers: ["command"]))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "Delete", modifiers: ["control"]))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "x", modifiers: ["command"]))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "v", modifiers: ["command"]))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "l", modifiers: ["command"]))
        #expect(!BrowserKeypressSafety.requiresTextEntryPreflight(key: "f", modifiers: ["command"]))
    }

    @Test("Trusted Google Docs paste shortcut stays outside generic keypress preflight")
    func trustedGoogleDocsPasteShortcutStaysOutsideGenericKeypressPreflight() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sessionPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ShelfBrowserSession.swift")
            .path
        let source = try String(contentsOfFile: sessionPath, encoding: .utf8)

        #expect(source.contains(#"inputJSON = try await keypress(key: "v", modifiers: ["command"], skipTextEntryPreflight: true)"#))
        #expect(BrowserKeypressSafety.requiresTextEntryPreflight(key: "v", modifiers: ["command"]))
    }

    @Test("Controlled browser defines all navigation keys exempted from preflight")
    func controlledBrowserDefinesAllNavigationKeysExemptedFromPreflight() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controllerPath = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Browser")
            .appendingPathComponent("ControlledBrowserController.swift")
            .path
        let source = try String(contentsOfFile: controllerPath, encoding: .utf8)

        #expect(source.contains(#"case "home":"#))
        #expect(source.contains(#"CDPKeyDefinition(key: "Home", code: "Home", virtualKeyCode: 36, text: nil)"#))
        #expect(source.contains(#"case "end":"#))
        #expect(source.contains(#"CDPKeyDefinition(key: "End", code: "End", virtualKeyCode: 35, text: nil)"#))
        #expect(source.contains(#"case "pageup":"#))
        #expect(source.contains(#"CDPKeyDefinition(key: "PageUp", code: "PageUp", virtualKeyCode: 33, text: nil)"#))
        #expect(source.contains(#"case "pagedown":"#))
        #expect(source.contains(#"CDPKeyDefinition(key: "PageDown", code: "PageDown", virtualKeyCode: 34, text: nil)"#))
        #expect(source.contains(#"case "space", "spacebar":"#))
        #expect(source.contains(#"CDPKeyDefinition(key: " ", code: "Space", virtualKeyCode: 32, text: " ")"#))
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

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
