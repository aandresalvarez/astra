import Testing
@testable import ASTRA

@Suite("WorkspaceInstructionMarkdown")
struct WorkspaceInstructionMarkdownTests {
    @Test("Consecutive plain lines are promoted to separate paragraphs")
    func consecutiveLinesArePromotedToSeparateParagraphs() {
        let input = "Line one.\nLine two."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == "Line one.\n\nLine two.")
    }

    @Test("Already blank-line-separated paragraphs are left untouched")
    func blankLineSeparatedParagraphsAreUntouched() {
        let input = "Rule one.\n\nRule two."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == input)
    }

    @Test("Lines inside a fenced code block are never split apart")
    func fencedCodeBlockLinesAreUntouched() {
        let input = "Before.\n```\nline a\nline b\n```\nAfter."
        let expected = "Before.\n\n```\nline a\nline b\n```\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == expected)
    }

    @Test("A fence delimiter indented up to 3 spaces is still recognized as a real fence")
    func fenceDelimiterIndentedUpToThreeSpacesIsRecognized() {
        let input = "Before.\n   ```\ncode line\n   ```\nAfter."
        let expected = "Before.\n\n   ```\ncode line\n   ```\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == expected)
    }

    @Test("A fence delimiter indented 4+ spaces is not treated as a real fence")
    func fenceDelimiterIndentedFourSpacesIsNotTreatedAsFence() {
        // CommonMark treats 4+ leading spaces as an indented code block, not a
        // fence — so this line should be promoted to its own paragraph like
        // any other line, not silently swallow everything after it as "inside
        // a fence that never closes".
        let input = "Before.\n    ```\nAfter."
        let expected = "Before.\n\n    ```\n\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == expected)
    }

    @Test("A shorter same-character fence line nested inside a longer fence doesn't close it early")
    func shorterNestedFenceDoesNotCloseEarly() {
        // A 4-backtick fence is a common way to show a 3-backtick example —
        // CommonMark only closes on a delimiter at least as long as the
        // opener, so the inner ``` lines must stay literal fence content.
        let input = "````\nExample:\n```\ncode\n```\n````"
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == input)
    }

    @Test("A different-character fence line nested inside a fence doesn't close it")
    func differentCharacterFenceDoesNotClose() {
        let input = "~~~\n```\ncontent\n~~~"
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == input)
    }

    @Test("A longer same-character closing fence still closes")
    func longerClosingFenceStillCloses() {
        // The closing line itself never gets a trailing blank line inserted
        // (fence marker lines always `continue` before that decision), so a
        // successful close here means the whole block is left byte-identical.
        let input = "```\ncode\n````\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == input)
    }

    @Test("One-rule-per-line prompts render as distinct text blocks, not a run-on paragraph")
    func oneRulePerLineRendersAsDistinctBlocks() {
        let instructions = """
        Always use first principles to address issues found.
        Once a solution is in, add detailed comments for the reviewer.
        Never skip the regression suite.
        """

        let prepared = WorkspaceInstructionMarkdown.preparedForRendering(instructions)
        let blocks = MarkdownASTBlockParser.parse(prepared) ?? []
        let textBlocks = blocks.filter {
            if case .text = $0.kind { return true }
            return false
        }

        #expect(textBlocks.map(\.content) == [
            "Always use first principles to address issues found.",
            "Once a solution is in, add detailed comments for the reviewer.",
            "Never skip the regression suite."
        ])
    }

    @Test("Consecutive list-marker lines still collapse into one list, each its own item")
    func consecutiveListMarkerLinesStayOneList() {
        let instructions = """
        - You are a Market Discovery Agent.
        - You are NOT a startup idea generator.
        - Your goal is to find markets that are easy to sell.
        """

        let prepared = WorkspaceInstructionMarkdown.preparedForRendering(instructions)
        let blocks = MarkdownASTBlockParser.parse(prepared) ?? []
        let listItems = blocks.compactMap { block -> String? in
            if case .listItem = block.kind { return block.content }
            return nil
        }

        #expect(listItems == [
            "You are a Market Discovery Agent.",
            "You are NOT a startup idea generator.",
            "Your goal is to find markets that are easy to sell."
        ])
    }

    @Test("Headings adjacent to body text still parse as headings")
    func headingsAdjacentToBodyTextStillParse() {
        let instructions = "# Role\nYou are a market discovery agent.\n# Task\nDiscover markets."

        let prepared = WorkspaceInstructionMarkdown.preparedForRendering(instructions)
        let blocks = MarkdownASTBlockParser.parse(prepared) ?? []
        let headings = blocks.compactMap { block -> Int? in
            if case .heading(let level) = block.kind { return level }
            return nil
        }

        #expect(headings == [1, 1])
    }

    @Test("A setext H1 heading keeps its title and === underline adjacent")
    func setextH1HeadingStaysAdjacent() {
        let input = "Title\n===\nBody text."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == "Title\n===\n\nBody text.")

        let blocks = MarkdownASTBlockParser.parse(WorkspaceInstructionMarkdown.preparedForRendering(input)) ?? []
        #expect(blocks.contains { if case .heading(1) = $0.kind { return true }; return false })
    }

    @Test("A setext H2 heading keeps its title and --- underline adjacent, not split into a divider")
    func setextH2HeadingStaysAdjacentNotADivider() {
        let input = "Title\n---\nBody text."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == "Title\n---\n\nBody text.")

        let blocks = MarkdownASTBlockParser.parse(WorkspaceInstructionMarkdown.preparedForRendering(input)) ?? []
        #expect(blocks.contains { if case .heading(2) = $0.kind { return true }; return false })
        #expect(!blocks.contains { $0.kind == .divider })
    }

    @Test("A GFM table's header, separator, and data rows all stay adjacent so the table parses whole")
    func tableRowsStayAdjacent() {
        let input = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == input)

        let blocks = MarkdownASTBlockParser.parse(WorkspaceInstructionMarkdown.preparedForRendering(input)) ?? []
        let table = blocks.first { $0.kind == .table }
        #expect(table != nil)
        // Not just "a table exists" — the data row must have survived inside
        // it rather than being split off into a disconnected paragraph.
        #expect(table?.content.contains("1") == true)
        #expect(table?.content.contains("2") == true)
    }

    @Test("Two prose lines that each mention a pipe, but form no real table, still get split apart")
    func pipeContainingProseLinesWithNoSeparatorRowAreSplit() {
        // Neither line is a genuine table separator row (dash-only cells) —
        // requiring one is what keeps a shell-pipeline example from being
        // mistaken for a table and merged back into a run-on paragraph.
        let input = "Run `ls | grep foo`.\nThen `cat file | wc -l`."
        let expected = "Run `ls | grep foo`.\n\nThen `cat file | wc -l`."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == expected)
    }

    @Test("A separator row with no header line above it is not treated as a table")
    func separatorRowWithNoPrecedingHeaderIsNotATable() {
        let input = "| --- | --- |\nAfter."
        let expected = "| --- | --- |\n\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == expected)
    }

    @Test("A fence-shaped line with trailing text doesn't close an open fence")
    func fenceLikeLineWithTrailingTextDoesNotClose() {
        // ```swift here is literal content demonstrating fence syntax, not a
        // close — CommonMark only lets a closing fence be followed by
        // whitespace. Everything through the final bare ``` must stay one
        // untouched block.
        let input = "```\ncode\n```swift\nmore code\n```\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == input)
    }

    @Test("Adjacent indented code lines are never split apart")
    func indentedCodeBlockLinesAreUntouched() {
        let input = "Before.\n    code line 1\n    code line 2\nAfter."
        let expected = "Before.\n\n    code line 1\n    code line 2\n\nAfter."
        #expect(WorkspaceInstructionMarkdown.preparedForRendering(input) == expected)

        let blocks = MarkdownASTBlockParser.parse(WorkspaceInstructionMarkdown.preparedForRendering(input)) ?? []
        let codeBlocks = blocks.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks.first?.content.contains("code line 1") == true)
        #expect(codeBlocks.first?.content.contains("code line 2") == true)
    }

    @Test("Summary counts real Markdown sections and falls back to a word count")
    func summaryCountsSectionsAndWords() {
        #expect(WorkspaceInstructionMarkdown.summary(for: "") == "")
        #expect(WorkspaceInstructionMarkdown.summary(for: "   \n  ") == "")
        #expect(WorkspaceInstructionMarkdown.summary(for: "test") == "1 word")

        let sectioned = "# A\n\nOne two three.\n\n# B\n\nFour five six."
        #expect(WorkspaceInstructionMarkdown.summary(for: sectioned) == "2 sections · 10 words")
    }

}
