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
        let password = try #require(controls.first { $0["label"] as? String == "Password" })
        let token = try #require(controls.first { $0["label"] as? String == "API token" })
        let email = try #require(controls.first { $0["label"] as? String == "Email" })

        #expect(password["value"] as? String == "[redacted-sensitive-input]")
        #expect(token["value"] as? String == "[redacted-sensitive-input]")
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
                  "selector": "#mrn",
                  "tag": "textarea",
                  "role": "textbox",
                  "type": "",
                  "label": "MRN-424242",
                  "name": "MRN-424242",
                  "placeholder": "Medical record number",
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
        #expect(control["label"] as? String == "[redacted-sensitive-input]")
        #expect(control["name"] as? String == "[redacted-sensitive-input]")
        #expect(control["value"] as? String == "[redacted-sensitive-input]")
        #expect(!compacted.contains("MRN-424242"))
    }

    @Test("snapshot script avoids sensitive value-derived metadata")
    func snapshotScriptAvoidsSensitiveValueDerivedMetadata() {
        let script = BrowserAutomationScripts.snapshotScript

        #expect(script.contains("const labelForSnapshot = (el) =>"))
        #expect(script.contains("const editableValueFor = (el) =>"))
        #expect(script.contains("el.isContentEditable"))
        #expect(script.contains("name: el.getAttribute(\"name\") || \"\""))
        #expect(script.contains("formControl && isSensitiveValueControl(formControl)"))
        #expect(script.contains("\"mrn\""))
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
