import Foundation
import Testing
@testable import ASTRA

@Suite("MarkdownSourceSyntaxTokenizer")
struct MarkdownSourceSyntaxTokenizerTests {
    @Test("Heading line yields a marker token and a leveled heading token with inline scanning")
    func headingLineYieldsMarkerAndHeadingTokens() {
        #expect(describe("# Role", MarkdownSourceSyntaxTokenizer.tokens(in: "# Role")) == [
            "headingMarker|# ",
            "heading(level: 1)|Role"
        ])

        #expect(describe("### Sub **bold**", MarkdownSourceSyntaxTokenizer.tokens(in: "### Sub **bold**")) == [
            "headingMarker|### ",
            "heading(level: 3)|Sub **bold**",
            "emphasisMarker|**",
            "bold|bold",
            "emphasisMarker|**"
        ])
    }

    @Test("List and blockquote markers are separated from their inline content")
    func listAndBlockquoteMarkersAreSeparated() {
        let listText = "- item one"
        #expect(describe(listText, MarkdownSourceSyntaxTokenizer.tokens(in: listText)) == [
            "listMarker|- ",
        ])

        let numberedText = "12. eleventh"
        #expect(describe(numberedText, MarkdownSourceSyntaxTokenizer.tokens(in: numberedText)) == [
            "listMarker|12. "
        ])

        let quoteText = "> quoted line"
        #expect(describe(quoteText, MarkdownSourceSyntaxTokenizer.tokens(in: quoteText)) == [
            "blockquoteMarker|> "
        ])

        let nestedQuoteText = "> > nested quote"
        #expect(describe(nestedQuoteText, MarkdownSourceSyntaxTokenizer.tokens(in: nestedQuoteText)) == [
            "blockquoteMarker|> > "
        ])
    }

    @Test("Divider lines are recognized for dash, asterisk, and underscore runs")
    func dividerLinesAreRecognized() {
        for divider in ["---", "----------", "***", "___"] {
            #expect(describe(divider, MarkdownSourceSyntaxTokenizer.tokens(in: divider)) == ["divider|\(divider)"])
        }
    }

    @Test("Fenced code blocks suppress inline scanning until the closing fence")
    func fencedCodeBlocksSuppressInlineScanning() {
        let text = "Before\n```\nlet x = 1 // **not bold**\n```\nAfter"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "codeFenceMarker|```",
            "codeBlockLine|let x = 1 // **not bold**",
            "codeFenceMarker|```"
        ])
    }

    @Test("A fence delimiter indented up to 3 spaces is still recognized")
    func fenceDelimiterIndentedUpToThreeSpacesIsRecognized() {
        let text = "   ```\ncode\n   ```"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "codeFenceMarker|   ```",
            "codeBlockLine|code",
            "codeFenceMarker|   ```"
        ])
    }

    @Test("A fence delimiter indented 4+ spaces is not a real fence and doesn't trap later lines")
    func indentedFenceDelimiterDoesNotTrapSubsequentLines() {
        let text = "    ```\n# Heading"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "headingMarker|# ",
            "heading(level: 1)|Heading"
        ])
    }

    @Test("Inline emphasis: bold does not get mistaken for two italics")
    func boldIsNotMistakenForItalics() {
        let text = "**bold** and *italic* and _also italic_ and __also bold__"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "emphasisMarker|**",
            "bold|bold",
            "emphasisMarker|**",
            "emphasisMarker|*",
            "italic|italic",
            "emphasisMarker|*",
            "emphasisMarker|_",
            "italic|also italic",
            "emphasisMarker|_",
            "emphasisMarker|__",
            "bold|also bold",
            "emphasisMarker|__"
        ])
    }

    @Test("Inline code span keeps backtick markers separate from the code content")
    func inlineCodeSpanSeparatesMarkersFromContent() {
        let text = "call `doThing()` now"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "codeSpanMarker|`",
            "codeSpan|doThing()",
            "codeSpanMarker|`"
        ])
    }

    @Test("Strikethrough is tokenized distinctly from emphasis")
    func strikethroughIsTokenizedDistinctly() {
        let text = "~~gone~~"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "emphasisMarker|~~",
            "strikethrough|gone",
            "emphasisMarker|~~"
        ])
    }

    @Test("Links split into bracket, label, and URL tokens")
    func linksSplitIntoBracketLabelAndURLTokens() {
        let text = "[docs](https://example.com)"
        #expect(describe(text, MarkdownSourceSyntaxTokenizer.tokens(in: text)) == [
            "linkBracket|[",
            "linkLabel|docs",
            "linkBracket|]",
            "linkBracket|(",
            "linkURL|https://example.com",
            "linkBracket|)"
        ])
    }

    @Test("A realistic one-rule-per-line prompt tokenizes every line independently")
    func realisticPromptTokenizesEveryLine() {
        let text = """
        # Role

        You are a Market Discovery Agent.
        You are NOT a startup idea generator.

        ------------------------------------------------------------

        # Core philosophy
        """

        let tokens = MarkdownSourceSyntaxTokenizer.tokens(in: text)
        let headingCount = tokens.filter {
            if case .heading = $0.kind { return true }
            return false
        }.count
        let dividerCount = tokens.filter { $0.kind == .divider }.count

        #expect(headingCount == 2)
        #expect(dividerCount == 1)
    }

    private func describe(_ text: String, _ tokens: [MarkdownSourceSyntaxTokenizer.Token]) -> [String] {
        let ns = text as NSString
        return tokens.map { "\($0.kind)|\(ns.substring(with: $0.range))" }
    }
}
