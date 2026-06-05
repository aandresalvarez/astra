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

    private func jsonObject(from json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
