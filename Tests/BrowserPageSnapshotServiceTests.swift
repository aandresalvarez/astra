import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Page Snapshot Service")
struct BrowserPageSnapshotServiceTests {
    @Test("full mode preserves original snapshot JSON")
    func fullModePreservesOriginalSnapshotJSON() throws {
        let json = #"{"ok":true,"url":"https://example.com","title":"Example","text":"Readable text","controls":[]}"#

        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: json,
            mode: .full,
            query: nil,
            limit: nil
        )

        #expect(compacted == json)
    }

    @Test("full mode redacts metadata for already-redacted sensitive snapshot values")
    func fullModeRedactsMetadataForAlreadyRedactedSensitiveSnapshotValues() throws {
        let json = """
        {"ok":true,"url":"https://example.com","title":"Example","text":"Sign in","controls":[{"selector":"#password","tag":"input","role":"textbox","type":"password","label":"Password","value":"[redacted-sensitive-input]"}]}
        """

        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: json,
            mode: .full,
            query: nil,
            limit: nil
        )

        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let control = try #require(controls.first)

        #expect(control["value"] as? String == "[redacted-sensitive-input]")
        #expect(control["selector"] as? String == "[redacted-sensitive-input]")
        #expect(control["label"] as? String == "[redacted-sensitive-input]")
        #expect(!compacted.contains("#password"))
    }

    @Test("full mode redacts secret-shaped metadata for already-redacted sensitive snapshot values")
    func fullModeRedactsSecretShapedMetadataForAlreadyRedactedSensitiveSnapshotValues() throws {
        let secret = "4f9c8a7b-91d2-4e6a-ac11-772b6612c08e"
        let json = """
        {
          "ok": true,
          "url": "https://example.com",
          "title": "Example",
          "text": "Preview echoes 4f9c8a7b-91d2-4e6a-ac11-772b6612c08e outside the input.",
          "controls": [
            {
              "selector": "#4f9c8a7b-91d2-4e6a-ac11-772b6612c08e",
              "tag": "input",
              "role": "textbox",
              "type": "password",
              "label": "4f9c8a7b-91d2-4e6a-ac11-772b6612c08e",
              "name": "4f9c8a7b-91d2-4e6a-ac11-772b6612c08e",
              "value": "[redacted-sensitive-input]"
            }
          ]
        }
        """

        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: json,
            mode: .full,
            query: nil,
            limit: nil
        )

        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let control = try #require(controls.first)

        #expect(object["text"] as? String == "Preview echoes [redacted-sensitive-input] outside the input.")
        #expect(control["selector"] as? String == "[redacted-sensitive-input]")
        #expect(control["label"] as? String == "[redacted-sensitive-input]")
        #expect(control["name"] as? String == "[redacted-sensitive-input]")
        #expect(!compacted.contains(secret))
    }

    @Test("snapshot output redacts sensitive focused and control values")
    func snapshotOutputRedactsSensitiveFocusedAndControlValues() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: sensitiveSnapshotJSON,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)

        let focused = try #require(object["focusedElement"] as? [String: Any])
        #expect(focused["value"] as? String == "[redacted-sensitive-input]")

        let controls = try #require(object["controls"] as? [[String: Any]])
        let redactedControls = controls.filter { $0["value"] as? String == "[redacted-sensitive-input]" }
        let email = try #require(controls.first { $0["label"] as? String == "Email" })

        #expect(redactedControls.count == 2)
        #expect(email["value"] as? String == "alvaro@example.com")
        #expect(!compacted.contains("correct-horse-battery-staple"))
        #expect(!compacted.contains("ghp_secret_token"))
    }

    @Test("snapshot output redacts sensitive values from text and derived labels")
    func snapshotOutputRedactsSensitiveValuesFromTextAndDerivedLabels() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/patient",
              "title": "Patient",
              "text": "Clinical note contains MRN-424242 and should not echo it.",
              "controls": [
                {
                  "selector": "#MRN-424242",
                  "tag": "textarea",
                  "role": "textbox",
                  "type": "",
                  "label": "MRN-424242",
                  "name": "MRN-424242",
                  "placeholder": "Paste MRN-424242",
                  "testID": "MRN-424242",
                  "href": "https://example.com/patient/MRN-424242",
                  "value": "MRN-424242"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let control = try #require(controls.first)

        #expect(object["text"] as? String == "Clinical note contains [redacted-sensitive-input] and should not echo it.")
        #expect(control["selector"] as? String == "[redacted-sensitive-input]")
        #expect(control["label"] as? String == "[redacted-sensitive-input]")
        #expect(control["name"] as? String == "[redacted-sensitive-input]")
        #expect(control["placeholder"] as? String == "[redacted-sensitive-input]")
        #expect(control["testID"] as? String == "[redacted-sensitive-input]")
        #expect(control["href"] as? String == "[redacted-sensitive-input]")
        #expect(control["value"] as? String == "[redacted-sensitive-input]")
        #expect(!compacted.contains("MRN-424242"))
    }

    @Test("snapshot output redacts encoded sensitive values from text")
    func snapshotOutputRedactsEncodedSensitiveValuesFromText() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/login",
              "title": "Login",
              "text": "Preview echoed correct%20horse outside the password field.",
              "controls": [
                {
                  "selector": "#password",
                  "tag": "input",
                  "role": "textbox",
                  "type": "password",
                  "label": "Password",
                  "value": "correct horse"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)

        #expect(object["text"] as? String == "Preview echoed [redacted-sensitive-input] outside the password field.")
        #expect(!compacted.contains("correct%20horse"))
        #expect(!compacted.contains("correct horse"))
    }

    @Test("snapshot output redacts sensitive values from title")
    func snapshotOutputRedactsSensitiveValuesFromTitle() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/patient",
              "title": "Patient MRN-424242",
              "text": "Patient chart",
              "controls": [
                {
                  "selector": "#mrn",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "MRN",
                  "value": "MRN-424242"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)

        #expect(object["title"] as? String == "Patient [redacted-sensitive-input]")
        #expect(!compacted.contains("MRN-424242"))
    }

    @Test("snapshot output redacts sensitive values from URL")
    func snapshotOutputRedactsSensitiveValuesFromURL() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/search?token=ghp_secret_token_123456",
              "title": "Search",
              "text": "Search page",
              "controls": [
                {
                  "selector": "#token",
                  "tag": "input",
                  "role": "textbox",
                  "type": "password",
                  "label": "Token",
                  "value": "ghp_secret_token_123456"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)

        #expect(object["url"] as? String == "https://example.com/search?token=[redacted-sensitive-input]")
        #expect(!compacted.contains("ghp_secret_token_123456"))
    }

    @Test("snapshot output still redacts metadata when sensitive value is already redacted")
    func snapshotOutputStillRedactsMetadataWhenSensitiveValueIsAlreadyRedacted() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/patient",
              "title": "Patient",
              "text": "Clinical note contains MRN-424242 and should not echo it.",
              "controls": [
                {
                  "selector": "#MRN-424242",
                  "tag": "input",
                  "role": "textbox",
                  "type": "password",
                  "label": "Password",
                  "name": "MRN-424242",
                  "placeholder": "Password",
                  "testID": "MRN-424242",
                  "href": "https://example.com/patient/MRN-424242",
                  "value": "[redacted-sensitive-input]"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let control = try #require(controls.first)

        #expect(object["text"] as? String == "Clinical note contains [redacted-sensitive-input] and should not echo it.")
        #expect(control["selector"] as? String == "[redacted-sensitive-input]")
        #expect(control["name"] as? String == "[redacted-sensitive-input]")
        #expect(control["testID"] as? String == "[redacted-sensitive-input]")
        #expect(control["href"] as? String == "[redacted-sensitive-input]")
        #expect(control["value"] as? String == "[redacted-sensitive-input]")
        #expect(!compacted.contains("MRN-424242"))
    }

    @Test("display redaction catches case escaped and percent encoded sensitive values")
    func displayRedactionCatchesCaseEscapedAndPercentEncodedSensitiveValues() {
        #expect(BrowserSensitiveInputRedactionPolicy.redactedDisplayText("token-abc", sensitiveValue: "TOKEN-ABC") == "[redacted-sensitive-input]")
        #expect(BrowserSensitiveInputRedactionPolicy.redactedDisplayText(#"#MRN\ 424242"#, sensitiveValue: "MRN 424242") == "[redacted-sensitive-input]")
        #expect(BrowserSensitiveInputRedactionPolicy.redactedDisplayText(#"#\31 23456"#, sensitiveValue: "123456") == "[redacted-sensitive-input]")
        #expect(BrowserSensitiveInputRedactionPolicy.redactedDisplayText("https://example.com/MRN%20424242", sensitiveValue: "MRN 424242") == "[redacted-sensitive-input]")
        #expect(BrowserSensitiveInputRedactionPolicy.redactedDisplayText("ghp_secret_token", sensitiveValue: "ghp_secret_token_123456") == "[redacted-sensitive-input]")
    }

    @Test("snapshot output redacts cardholder and generic payment values")
    func snapshotOutputRedactsCardholderAndGenericPaymentValues() throws {
        let cardholder = "Maya Private"
        let cardNumber = "4111111111111111"
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/checkout",
              "title": "Checkout",
              "text": "Pay with saved card",
              "controls": [
                {
                  "selector": "#cc-name",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "Name on card",
                  "name": "cc-name",
                  "autocomplete": "cc-name",
                  "value": "\(cardholder)"
                },
                {
                  "selector": "#payment-method",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "Payment method",
                  "name": "paymentMethod",
                  "value": "\(cardNumber)"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])

        #expect(controls.compactMap { $0["value"] as? String } == [
            "[redacted-sensitive-input]",
            "[redacted-sensitive-input]"
        ])
        #expect(!compacted.contains(cardholder))
        #expect(!compacted.contains(cardNumber))
    }

    @Test("snapshot output redacts birthday autocomplete values")
    func snapshotOutputRedactsBirthdayAutocompleteValues() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/profile",
              "title": "Profile",
              "text": "Birthday preview 2001-02-03",
              "controls": [
                {
                  "selector": "#field",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "Value",
                  "autocomplete": "bday",
                  "value": "2001-02-03"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let control = try #require(controls.first)

        #expect(control["value"] as? String == "[redacted-sensitive-input]")
        #expect(object["text"] as? String == "Birthday preview [redacted-sensitive-input]")
        #expect(!compacted.contains("2001-02-03"))
    }

    @Test("snapshot output redacts empty sensitive metadata")
    func snapshotOutputRedactsEmptySensitiveMetadata() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/settings",
              "title": "Settings",
              "text": "Rotate api_token_sk_live_123 before publishing.",
              "controls": [
                {
                  "selector": "#api_token_sk_live_123",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "API token",
                  "name": "api_token_sk_live_123",
                  "value": ""
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let control = try #require(controls.first)

        #expect(object["text"] as? String == "Rotate [redacted-sensitive-input] before publishing.")
        #expect(control["selector"] as? String == "[redacted-sensitive-input]")
        #expect(control["name"] as? String == "[redacted-sensitive-input]")
        #expect(control["value"] as? String == "")
        #expect(!compacted.contains("api_token_sk_live_123"))
    }

    @Test("snapshot output redacts independent sensitive metadata and formatted values")
    func snapshotOutputRedactsIndependentSensitiveMetadataAndFormattedValues() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/checkout",
              "title": "Checkout",
              "text": "Saved card 4111 1111 1111 1111 and api_token_sk_live_123 are visible.",
              "controls": [
                {
                  "selector": "#api_token_sk_live_123",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "API token",
                  "name": "api_token_sk_live_123",
                  "value": "rotated"
                },
                {
                  "selector": "#cc-number",
                  "tag": "input",
                  "role": "textbox",
                  "type": "text",
                  "label": "Card number",
                  "autocomplete": "cc-number",
                  "value": "4111111111111111"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let redactedControls = controls.filter { $0["value"] as? String == "[redacted-sensitive-input]" }

        #expect(object["text"] as? String == "Saved card [redacted-sensitive-input] and [redacted-sensitive-input] are visible.")
        #expect(redactedControls.count == 2)
        #expect(redactedControls.allSatisfy { control in
            (control["selector"] as? String)?.contains("api_token_sk_live_123") != true
                && (control["selector"] as? String)?.contains("cc-number") != true
        })
        let namedControls = redactedControls.filter { ($0["name"] as? String)?.isEmpty == false }
        #expect(namedControls.allSatisfy { $0["name"] as? String == "[redacted-sensitive-input]" })
        #expect(!compacted.contains("api_token_sk_live_123"))
        #expect(!compacted.contains("4111 1111 1111 1111"))
    }

    @Test("snapshot text redaction skips very short sensitive values")
    func snapshotTextRedactionSkipsVeryShortSensitiveValues() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: """
            {
              "ok": true,
              "url": "https://example.com/login",
              "title": "Login",
              "text": "Step 1 asks a normal question.",
              "controls": [
                {
                  "selector": "#password",
                  "tag": "input",
                  "role": "textbox",
                  "type": "password",
                  "label": "Password",
                  "value": "1"
                }
              ]
            }
            """,
            mode: .full,
            query: nil,
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])
        let password = try #require(controls.first)

        #expect(object["text"] as? String == "Step 1 asks a normal question.")
        #expect(password["value"] as? String == "[redacted-sensitive-input]")
    }

    @Test("snapshot script avoids sensitive value-derived metadata")
    func snapshotScriptAvoidsSensitiveValueDerivedMetadata() {
        let script = BrowserAutomationScripts.snapshotScript

        #expect(script.contains("const labelForSnapshot = (el) =>"))
        #expect(script.contains("const editableValueFor = (el) =>"))
        #expect(script.contains("const valueControlForTextNode = (el) =>"))
        #expect(script.contains("const sensitiveControlForTextNode = (el) =>"))
        #expect(script.contains("parentLabel?.control && isSensitiveValueControl(parentLabel.control)"))
        #expect(script.contains("document.querySelector(\"[aria-labelledby~='\" + esc(node.id) + \"']\")"))
        #expect(script.contains("el.isContentEditable"))
        #expect(script.contains("if (node === document.body) break"))
        #expect(script.contains("const redactedMetadataForSnapshot = (el, value) =>"))
        #expect(script.contains("const metadataValueForSnapshot = (el, rawValue, value) =>"))
        #expect(script.contains("const valueContainsMetadata = normalizedValue.length >= prefixLength"))
        #expect(script.contains("normalizedValue.includes(normalizedMetadata)"))
        #expect(script.contains("const isEditablePaymentField = (el) =>"))
        #expect(script.contains("const sensitiveFieldTerms = \(BrowserSensitiveInputRedactionPolicy.javaScriptArrayLiteral(BrowserSensitiveInputRedactionPolicy.sensitiveFieldTerms, indentation: "      "));"))
        #expect(script.contains("const paymentFieldTerms = \(BrowserSensitiveInputRedactionPolicy.javaScriptArrayLiteral(BrowserSensitiveInputRedactionPolicy.paymentFieldTerms, indentation: "      "));"))
        #expect(script.contains("const sensitiveAutocompleteTerms = \(BrowserSensitiveInputRedactionPolicy.javaScriptArrayLiteral(BrowserSensitiveInputRedactionPolicy.sensitiveAutocompleteTokens, indentation: "      "));"))
        #expect(script.contains("selector: selectorFor(el)"))
        #expect(script.contains("selector: selectorFor(active)"))
        #expect(script.contains("return metadataValueForSnapshot(el, editableValueFor(el), label)"))
        #expect(script.contains("name: metadataValueForSnapshot(el, rawValue, el.getAttribute(\"name\") || \"\")"))
        #expect(script.contains("if (sensitiveControlForTextNode(parent)) continue"))
        #expect(script.contains("\"cc-name\""))
        #expect(script.contains("\"payment\""))
        #expect(script.contains("\"mrn\""))
        #expect(!script.contains("label === value || label.includes(value)"))
        #expect(!script.contains("name: labelFor(el)"))
    }

    @Test("snapshot control filtering does not match redacted sensitive values")
    func snapshotControlFilteringDoesNotMatchRedactedSensitiveValues() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: sensitiveSnapshotJSON,
            mode: .controls,
            query: "ghp_secret_token",
            limit: nil
        )
        let object = try jsonObject(from: compacted)
        let controls = try #require(object["controls"] as? [[String: Any]])

        #expect(controls.isEmpty)
        #expect(!compacted.contains("ghp_secret_token"))
    }

    @Test("summary mode includes compact text, controls, and query matches")
    func summaryModeIncludesCompactTextControlsAndMatches() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: snapshotJSON,
            mode: .summary,
            query: "Save",
            limit: 18
        )
        let object = try jsonObject(from: compacted)

        #expect(object["ok"] as? Bool == true)
        #expect(object["url"] as? String == "https://example.com/form")
        #expect(object["title"] as? String == "Form")
        #expect(object["controlCount"] as? Int == 3)
        #expect(object["text"] as? String == "Save this draft an")

        let controls = try #require(object["controls"] as? [[String: Any]])
        #expect(controls.count == 2)
        #expect(controls.compactMap { $0["label"] as? String } == ["Save", "Save as"])

        let matches = try #require(object["matches"] as? [[String: Any]])
        #expect(matches.count == 2)
        #expect(matches.first?["index"] as? Int == 0)
    }

    @Test("controls mode applies query and lower-bound limit")
    func controlsModeAppliesQueryAndLowerBoundLimit() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: snapshotJSON,
            mode: .controls,
            query: "button",
            limit: 0
        )
        let object = try jsonObject(from: compacted)

        #expect(object["controlCount"] as? Int == 3)
        let controls = try #require(object["controls"] as? [[String: Any]])
        #expect(controls.count == 1)
        #expect(controls.first?["role"] as? String == "button")
    }

    @Test("text mode truncates and returns case-insensitive matches")
    func textModeTruncatesAndReturnsMatches() throws {
        let compacted = try BrowserPageSnapshotService.compactSnapshot(
            json: snapshotJSON,
            mode: .text,
            query: "draft",
            limit: 1
        )
        let object = try jsonObject(from: compacted)

        #expect(object["text"] as? String == "S")
        let matches = try #require(object["matches"] as? [[String: Any]])
        #expect(matches.count == 1)
        #expect(matches.first?["index"] as? Int == 10)
        let snippet = try #require(matches.first?["snippet"] as? String)
        #expect(snippet.contains("draft"))
    }

    @Test("fill script redacts sensitive failed and successful target results")
    func fillScriptRedactsSensitiveFailedAndSuccessfulTargetResults() {
        let script = BrowserAutomationScripts.typeScript(
            selector: "#secret",
            text: "new",
            clear: true
        )

        #expect(script.contains("const currentValueFor = (target) =>"))
        #expect(script.contains("const redactSensitiveResultTarget = (result, target, value) =>"))
        #expect(script.contains("const sensitiveResultObject = (result) =>"))
        #expect(script.contains("if (!target.ok) return JSON.stringify(redactSensitiveResultTarget(publicTarget(target), target.el, currentValueFor(target.el)))"))
        #expect(script.contains("return JSON.stringify(redactSensitiveResultTarget(result, el, currentValueFor(el)))"))
        #expect(script.contains(#"for (const key of ["selector", "requestedSelector", "label", "name", "placeholder", "testID", "href"])"#))
        #expect(script.contains("redactSensitiveResultMetadata(result[key], value)"))
        #expect(script.contains("normalizedValue.includes(normalizedRaw)"))
        #expect(script.contains("&& (includesAny(text, sensitiveResultTerms) || includesAny(text, paymentResultTerms));"))
        #expect(script.contains("sensitiveMetadataCandidate(raw) ? redactedInputValue : raw"))
        #expect(!script.contains("&& (/[0-9]/.test(text) || text.includes(\"-\") || text.includes(\"_\") || text.includes(\"%\") || value.length > 20)"))
        #expect(!script.contains("redactSensitiveResultTarget(result, el, next);\n          result.cleared = clear;"))
    }

    @Test("snapshot script redacts visible text from raw sensitive values before returning")
    func snapshotScriptRedactsVisibleTextFromRawSensitiveValuesBeforeReturning() {
        let script = BrowserAutomationScripts.snapshotScript

        #expect(script.contains("const rawSensitiveValues = []"))
        #expect(script.contains("const visibleControls = allControls()"))
        #expect(script.contains("for (const entry of visibleControls)"))
        #expect(script.contains("rawSensitiveValues.push(rawValue)"))
        #expect(script.contains("const snapshotSensitiveValues = rawSensitiveValues.concat"))
        #expect(script.contains("text: redactedVisibleText(visibleText(), snapshotSensitiveValues)"))
        #expect(script.contains("role: roleFor(active)"))
        #expect(script.contains("encodeURIComponent"))
        #expect(script.contains("const formattedDigitPattern = (value) =>"))
        #expect(script.contains("redacted = redacted.replace(pattern,"))
        #expect(script.contains("\"bday\""))
    }

    private var snapshotJSON: String {
        """
        {
          "ok": true,
          "url": "https://example.com/form",
          "title": "Form",
          "text": "Save this draft and then Save as a copy.",
          "viewport": {"width": 1000, "height": 800},
          "focusedElement": {"selector": "#name"},
          "controls": [
            {"label": "Save", "role": "button", "selector": "#save"},
            {"label": "Cancel", "role": "button", "selector": "#cancel"},
            {"label": "Save as", "role": "menuitem", "selector": "#save-as"}
          ]
        }
        """
    }

    private var sensitiveSnapshotJSON: String {
        """
        {
          "ok": true,
          "url": "https://example.com/login",
          "title": "Login",
          "text": "Sign in",
          "viewport": {"width": 1000, "height": 800},
          "focusedElement": {
            "selector": "#password",
            "tag": "input",
            "role": "textbox",
            "type": "password",
            "label": "Password",
            "value": "correct-horse-battery-staple"
          },
          "controls": [
            {
              "selector": "#password",
              "tag": "input",
              "role": "textbox",
              "type": "password",
              "label": "Password",
              "name": "Password",
              "value": "correct-horse-battery-staple"
            },
            {
              "selector": "#token",
              "tag": "input",
              "role": "textbox",
              "type": "text",
              "label": "API token",
              "name": "api_token",
              "placeholder": "Paste token",
              "value": "ghp_secret_token"
            },
            {
              "selector": "#email",
              "tag": "input",
              "role": "textbox",
              "type": "email",
              "label": "Email",
              "name": "Email",
              "value": "alvaro@example.com"
            }
          ]
        }
        """
    }

    private func jsonObject(from json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
