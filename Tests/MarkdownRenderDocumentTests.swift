import Foundation
import Testing
@testable import ASTRA

@Suite("Markdown render documents")
struct MarkdownRenderDocumentTests {
    @Test("An unchanged source reuses block identity and its suggestion projection")
    func unchangedSourceReusesDocument() {
        let text = "## Suggested next steps\n\n- Verify \(UUID().uuidString)"
        let first = MarkdownTextView.cachedRenderDocument(text, includesSuggestions: true)
        let second = MarkdownTextView.cachedRenderDocument(text, includesSuggestions: true)
        #expect(first === second)
        #expect(!first.suggestions.isEmpty)
        #expect(first.blocks.map(\.id) == second.blocks.map(\.id))
    }

    @Test("A source change replaces both markdown and suggested actions")
    func sourceChangeRebuildsProjection() {
        let first = MarkdownTextView.cachedRenderDocument("## Next steps\n\n- Export a PDF", includesSuggestions: true)
        let second = MarkdownTextView.cachedRenderDocument("## Next steps\n\n- Add speaker notes", includesSuggestions: true)
        #expect(first !== second)
        let actions = second.blocks.flatMap { second.suggestions[$0.id] ?? [] }
        #expect(actions.map(\.title) == ["Add speaker notes"])
        #expect(!second.blocks.contains { $0.content.contains("Export") })
    }

    @Test("Callback availability participates in cache identity")
    func callbackAvailabilityChangesProjection() {
        let text = "## Next steps\n\n- Export a PDF"
        let plain = MarkdownTextView.cachedRenderDocument(text, includesSuggestions: false)
        let actionable = MarkdownTextView.cachedRenderDocument(text, includesSuggestions: true)
        #expect(plain !== actionable)
        #expect(plain.suggestions.isEmpty)
        #expect(actionable.blocks.flatMap { actionable.suggestions[$0.id] ?? [] }.map(\.title) == ["Export a PDF"])
        #expect(plain.blocks.map(\.content) == actionable.blocks.map(\.content))
    }

    @Test("Cached render documents preserve the existing parser's content and formatting",
          arguments: [
            "## Heading\r\n\r\nParagraph with `code` and **bold**.",
            "```swift\nlet x = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |",
            "Sentence one.\nSentence two.\n\n> Note with detail",
            ""
          ])
    func cachedDocumentPreservesParsing(text: String) {
        let expected = MarkdownTextView.parse(text)
        let actual = MarkdownTextView.cachedRenderDocument(text, includesSuggestions: false).blocks
        #expect(actual.map(\.kind) == expected.map(\.kind))
        #expect(actual.map(\.content) == expected.map(\.content))
    }

    @Test("Suggestion sections end at a divider or any heading and exclude nested bullets")
    func suggestionBoundariesAndOrder() {
        typealias Block = MarkdownTextView.MarkdownBlock
        let blocks: [Block] = [
            Block(kind: .listItem(depth: 0, marker: "•"), content: "Ordinary item"),
            Block(kind: .heading(level: 2), content: "  Suggested NEXT steps  "),
            Block(kind: .listItem(depth: 0, marker: "•"), content: "**Export** a PDF"),
            Block(kind: .listItem(depth: 1, marker: "◦"), content: "Nested informational detail"),
            Block(kind: .blank, content: ""),
            Block(kind: .listItem(depth: 0, marker: "•"), content: "Add speaker notes"),
            Block(kind: .divider, content: ""),
            Block(kind: .listItem(depth: 0, marker: "•"), content: "After divider"),
            Block(kind: .heading(level: 2), content: "Next steps"),
            Block(kind: .listItem(depth: 0, marker: "1."), content: "Validate the result"),
            Block(kind: .heading(level: 3), content: "Other details"),
            Block(kind: .listItem(depth: 0, marker: "•"), content: "After another heading"),
            Block(kind: .text, content: "Next suggestions: refine contrast, or change CTA colors.")
        ]
        #expect(MarkdownTextView.suggestedNextActions(in: blocks).map(\.title) == [
            "Export a PDF", "Add speaker notes", "Validate the result", "refine contrast", "change CTA colors"
        ])
    }
}
