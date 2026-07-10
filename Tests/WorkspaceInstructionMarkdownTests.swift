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

    @Test("Summary counts real Markdown sections and falls back to a word count")
    func summaryCountsSectionsAndWords() {
        #expect(WorkspaceInstructionMarkdown.summary(for: "") == "")
        #expect(WorkspaceInstructionMarkdown.summary(for: "   \n  ") == "")
        #expect(WorkspaceInstructionMarkdown.summary(for: "test") == "1 word")

        let sectioned = "# A\n\nOne two three.\n\n# B\n\nFour five six."
        #expect(WorkspaceInstructionMarkdown.summary(for: sectioned) == "2 sections · 10 words")
    }

}
