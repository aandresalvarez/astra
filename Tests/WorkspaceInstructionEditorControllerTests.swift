import AppKit
import Testing
@testable import ASTRA

@Suite("WorkspaceInstructionEditorController")
@MainActor
struct WorkspaceInstructionEditorControllerTests {
    @Test("Bold with no selection inserts a placeholder and selects it")
    func boldWithNoSelectionInsertsPlaceholder() {
        let (controller, textView) = makeController(text: "", selection: NSRange(location: 0, length: 0))
        controller.toggleBold()

        #expect(textView.string == "**bold text**")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 9))
    }

    @Test("Bold with a selection wraps it and places the cursor after")
    func boldWithSelectionWrapsAndMovesCursorAfter() {
        let (controller, textView) = makeController(text: "hello world", selection: NSRange(location: 0, length: 5))
        controller.toggleBold()

        #expect(textView.string == "**hello** world")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
    }

    @Test("Italic and inline code wrap with their own markers")
    func italicAndInlineCodeWrapWithOwnMarkers() {
        let (italicController, italicView) = makeController(text: "word", selection: NSRange(location: 0, length: 4))
        italicController.toggleItalic()
        #expect(italicView.string == "*word*")

        let (codeController, codeView) = makeController(text: "word", selection: NSRange(location: 0, length: 4))
        codeController.toggleInlineCode()
        #expect(codeView.string == "`word`")
    }

    @Test("Heading applies the requested level")
    func headingAppliesRequestedLevel() {
        let (controller, textView) = makeController(text: "Title", selection: NSRange(location: 0, length: 0))
        controller.applyHeading(level: 2)

        #expect(textView.string == "## Title")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test("Heading replaces an existing marker instead of stacking a new one")
    func headingReplacesExistingMarker() {
        let (controller, textView) = makeController(text: "# Title", selection: NSRange(location: 3, length: 0))
        controller.applyHeading(level: 3)

        #expect(textView.string == "### Title")
    }

    @Test("Bulleted list prefixes a single line and toggles back off")
    func bulletedListPrefixesAndToggles() {
        let (controller, textView) = makeController(text: "item", selection: NSRange(location: 0, length: 4))
        controller.toggleBulletList()
        #expect(textView.string == "- item")

        controller.toggleBulletList()
        #expect(textView.string == "item")
    }

    @Test("Bulleted list prefixes every non-blank line touched by a multi-line selection")
    func bulletedListPrefixesEveryTouchedLine() {
        let text = "one\ntwo\nthree"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let (controller, textView) = makeController(text: text, selection: fullRange)
        controller.toggleBulletList()

        #expect(textView.string == "- one\n- two\n- three")
    }

    @Test("Numbered list numbers touched lines sequentially and toggles back off")
    func numberedListNumbersSequentiallyAndToggles() {
        let text = "a\nb\nc"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let (controller, textView) = makeController(text: text, selection: fullRange)
        controller.toggleNumberedList()
        #expect(textView.string == "1. a\n2. b\n3. c")

        let renumberRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.setSelectedRange(renumberRange)
        controller.toggleNumberedList()
        #expect(textView.string == "a\nb\nc")
    }

    @Test("Quote prefixes touched lines")
    func quotePrefixesTouchedLines() {
        let (controller, textView) = makeController(text: "wisdom", selection: NSRange(location: 0, length: 6))
        controller.toggleQuote()
        #expect(textView.string == "> wisdom")
    }

    @Test("Link with no selection selects the label placeholder")
    func linkWithNoSelectionSelectsLabelPlaceholder() {
        let (controller, textView) = makeController(text: "", selection: NSRange(location: 0, length: 0))
        controller.insertLink()

        #expect(textView.string == "[link text](url)")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 9))
    }

    @Test("Link with a selection wraps it as the label and selects the URL placeholder")
    func linkWithSelectionWrapsAsLabelAndSelectsURL() {
        let (controller, textView) = makeController(text: "docs", selection: NSRange(location: 0, length: 4))
        controller.insertLink()

        #expect(textView.string == "[docs](url)")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 3))
    }

    @Test("Code block with no selection selects the code placeholder")
    func codeBlockWithNoSelectionSelectsPlaceholder() {
        let (controller, textView) = makeController(text: "", selection: NSRange(location: 0, length: 0))
        controller.insertCodeBlock()

        #expect(textView.string == "```\ncode\n```")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 4))
    }

    @Test("Code block with a selection wraps it and places the cursor after")
    func codeBlockWithSelectionWrapsAndMovesCursorAfter() {
        let (controller, textView) = makeController(text: "let x = 1", selection: NSRange(location: 0, length: 9))
        controller.insertCodeBlock()

        #expect(textView.string == "```\nlet x = 1\n```")
        #expect(textView.selectedRange() == NSRange(location: 17, length: 0))
    }

    // MARK: - Fixture

    private func makeController(
        text: String,
        selection: NSRange
    ) -> (WorkspaceInstructionEditorController, NSTextView) {
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(selection)
        let controller = WorkspaceInstructionEditorController()
        controller.textView = textView
        return (controller, textView)
    }
}
