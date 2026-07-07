import Testing
import AppKit
import Combine
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - MarkdownTextView

@Suite("MarkdownTextView")
struct MarkdownTextViewTests {

    @Test("Task answer result bodies stay selectable")
    func taskAnswerResultBodiesStaySelectable() {
        #expect(TaskAnswerTextSelectionPolicy.liveAnswerTextIsSelectable)
        #expect(TaskAnswerTextSelectionPolicy.completedAnswerMarkdownIsSelectable)
    }

    @Test("Malformed schedule markdown is rendered as text instead of trapping")
    func malformedScheduleMarkdownDoesNotTrap() {
        let malformed = "Schedule result: [unterminated link with agent output"

        let attributed = MarkdownTextView.markdownAttributed(malformed)

        #expect(String(attributed.characters) == malformed)
    }

    @Test("Bare URLs are linked with the shared markdown linkifier")
    func bareURLsAreLinked() {
        let attributed = MarkdownTextView.markdownAttributed("Visit https://example.com/docs")
        let links = attributed.runs.compactMap(\.link)
        let expected = URL(string: "https://example.com/docs")!

        #expect(links.contains(expected))
    }

    @Test("Long bare URLs render as compact links")
    func longBareURLsRenderAsCompactLinks() {
        let rawURL = "https://docs.google.com/document/d/abcdefghijklmnopqrstuvwxyz0123456789/edit?usp=sharing"
        let attributed = MarkdownTextView.markdownAttributed("Open \(rawURL)")
        let rendered = String(attributed.characters)
        let expected = URL(string: rawURL)!

        #expect(rendered.contains("docs.google.com"))
        #expect(rendered.contains("..."))
        #expect(!rendered.contains(rawURL))
        #expect(attributed.runs.compactMap(\.link).contains(expected))
    }

    @Test("Markdown linkifier returns stable attributed output from cache")
    func markdownLinkifierCacheIsStable() {
        MarkdownLinkifier.clearCacheForTests()

        let source = "Read **docs** at https://example.com/docs"
        let first = MarkdownLinkifier.markdownAttributed(source)
        let second = MarkdownLinkifier.markdownAttributed(source)

        #expect(String(first.characters) == String(second.characters))
        #expect(first.runs.compactMap(\.link) == second.runs.compactMap(\.link))
    }

    @Test("Parser recognizes GitHub tables without outer pipes")
    func parserRecognizesGitHubTablesWithoutOuterPipes() {
        let source = """
        Name | Score | Status
        --- | ---: | :---
        Ada | 10 | **ready**
        Grace | 8 | waiting
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .table)
        #expect(blocks.first?.content.contains("Name | Score | Status") == true)
        #expect(blocks.first?.content.contains("Ada | 10 | **ready**") == true)
    }

    @Test("Parser handles empty table cells without formatter crash")
    func parserHandlesEmptyTableCellsWithoutFormatterCrash() {
        let source = """
        Name | Score | Status
        --- | ---: | :---
        Ada | 10 |
        Grace | | waiting
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .table)
        #expect(blocks.first?.content.contains("Ada | 10 |") == true)
        #expect(blocks.first?.content.contains("Grace |  | waiting") == true)
    }

    @Test("Parser formats tables for selectable Markdown preview")
    func parserFormatsTablesForSelectableMarkdownPreview() {
        let source = """
        Name | Score | Status
        --- | ---: | :---
        Ada | 10 | ready
        Grace | 8 | waiting
        """

        let rendered = MarkdownTextView.monospacedTableText(source)

        #expect(rendered.contains("Name"))
        #expect(rendered.contains("Score"))
        #expect(rendered.contains("-----"))
        #expect(rendered.contains("Ada"))
        #expect(!rendered.contains("--- | ---: | :---"))
    }

    @Test("Parser keeps heading followed by pipe table as separate blocks")
    func parserKeepsHeadingFollowedByPipeTableAsSeparateBlocks() {
        let source = """
        ### What passed across all runs (death-specific)

        | Model/Test | Status | Details |
        |---|---|---|
        | `lpch_deaths` | PASS | 15.1k rows (prod) |
        | `shc_deaths` | PASS | 504.5k rows (prod) |
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .heading(level: 3))
        #expect(blocks[0].content == "What passed across all runs (death-specific)")
        #expect(blocks[1].kind == .table)
        #expect(blocks[1].content.contains("Model/Test | Status | Details"))
        #expect(blocks[1].content.contains("`lpch_deaths` | PASS | 15.1k rows (prod)"))
    }

    @Test("Chunk joiner preserves table block boundary after heading")
    func chunkJoinerPreservesTableBlockBoundaryAfterHeading() {
        let joined = MarkdownRenderPreparation.joinChunks([
            "### What passed across all runs (death-specific)\n",
            """
            | Model/Test | Status | Details |
            |---|---|---|
            | `lpch_deaths` | PASS | 15.1k rows (prod) |
            """
        ])

        #expect(joined.contains("death-specific)\n\n| Model/Test | Status | Details |"))
        #expect(MarkdownTextView.parse(joined).contains { $0.kind == .table })
    }

    @Test("Display preparation repairs missing blank line before table")
    func displayPreparationRepairsMissingBlankLineBeforeTable() {
        let prepared = MarkdownRenderPreparation.prepareForDisplay("""
        ### What passed across all runs (death-specific)
        | Model/Test | Status | Details |
        |---|---|---|
        | `lpch_deaths` | PASS | 15.1k rows (prod) |
        """)

        #expect(prepared.contains("death-specific)\n\n| Model/Test | Status | Details |"))

        let blocks = MarkdownTextView.parse(prepared)
        #expect(blocks.map(\.kind) == [.heading(level: 3), .table])
    }

    @Test("Display preparation repairs same-line heading table corruption")
    func displayPreparationRepairsSameLineHeadingTableCorruption() {
        let prepared = MarkdownRenderPreparation.prepareForDisplay("""
        ### What passed across all runs (death-specific) | Model/Test | Status | Details |
        |---|---|---|
        | `lpch_deaths` | PASS | 15.1k rows (prod) |
        """)

        #expect(prepared.contains("death-specific)\n\n| Model/Test | Status | Details |"))

        let blocks = MarkdownTextView.parse(prepared)
        #expect(blocks.map(\.kind) == [.heading(level: 3), .table])
    }

    @Test("Display preparation preserves compact hash table headers")
    func displayPreparationPreservesCompactHashTableHeaders() {
        let prepared = MarkdownRenderPreparation.prepareForDisplay("""
        #PR | Status | Details
        --- | --- | ---
        123 | Open | Needs review
        """)

        #expect(prepared.contains("#PR | Status | Details"))
        #expect(!prepared.contains("#PR\n\n| Status | Details"))

        let blocks = MarkdownTextView.parse(prepared)
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .table)
        #expect(blocks.first?.content.contains("#PR | Status | Details") == true)
    }

    @Test("Joined response payloads normalize after preserving chunk boundaries")
    func joinedResponsePayloadsNormalizeAfterPreservingChunkBoundaries() {
        let joined = TaskRunAnswerPresentationPolicy.joinedResponsePayloads([
            "```swift\n",
            "    let value = 1\n",
            "```\n"
        ])

        #expect(joined.contains("```swift\n    let value = 1\n```"))
    }

    @Test("Joined response payloads drop protocol marker chunks without dropping answer")
    func joinedResponsePayloadsDropProtocolMarkerChunksWithoutDroppingAnswer() {
        let joined = TaskRunAnswerPresentationPolicy.joinedResponsePayloads([
            "ASTRA_EVENT {\"type\":\"agent.response\"}",
            "Final answer is visible."
        ])

        #expect(joined == "Final answer is visible.")
    }

    @Test("Display preparation preserves fenced table-looking text")
    func displayPreparationPreservesFencedTableLookingText() {
        let source = """
        Before
        ```markdown
        ### Heading | A | B |
        |---|---|
        ```
        After
        """

        let prepared = MarkdownRenderPreparation.prepareForDisplay(source)

        #expect(prepared.contains("```markdown\n### Heading | A | B |\n|---|---|\n```"))
        #expect(MarkdownTextView.parse(prepared).contains { $0.kind == .codeBlock(language: "markdown") })
    }

    @Test("Parser recognizes additional heading forms")
    func parserRecognizesAdditionalHeadingForms() {
        let source = """
        Report Title
        ============

        #### Deep Section ####

        #Compact Heading
        """

        let blocks = MarkdownTextView.parse(source)
        let headings = blocks.compactMap { block -> (Int, String)? in
            guard case .heading(let level) = block.kind else { return nil }
            return (level, block.content)
        }

        #expect(headings.map(\.0) == [1, 4, 1])
        #expect(headings.map(\.1) == ["Report Title", "Deep Section", "Compact Heading"])
    }

    @Test("Parser normalizes soft-wrapped prose paragraphs")
    func parserNormalizesSoftWrappedProseParagraphs() {
        let source = """
        I can use the browser.The page is blank
        and has no text to summarize.
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .text)
        #expect(blocks.first?.content == "I can use the browser. The page is blank and has no text to summarize.")
    }

    @Test("Parser preserves fenced code block line breaks")
    func parserPreservesFencedCodeBlockLineBreaks() {
        let source = """
        ```json
        {"ok": true}
        {"done": false}
        ```
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .codeBlock(language: "json"))
        #expect(blocks.first?.content == "{\"ok\": true}\n{\"done\": false}")
    }

    @Test("Parser preserves ordered list markers")
    func parserPreservesOrderedListMarkers() {
        let blocks = MarkdownTextView.parse("""
        1. First step
        2. Second step
        """)

        let listItems = blocks.compactMap { block -> (String, String)? in
            guard case .listItem(_, let marker) = block.kind else { return nil }
            return (marker, block.content)
        }

        #expect(listItems.map(\.0) == ["1.", "2."])
        #expect(listItems.map(\.1) == ["First step", "Second step"])
    }

    @Test("Suggested next actions include top-level bullets under the next steps heading")
    func suggestedNextActionsIncludeTopLevelBulletsUnderHeading() {
        let blocks = MarkdownTextView.parse("""
        ## Next steps

        - **Export** a PDF
          - Keep this nested note informational
        - Add speaker notes
        """)

        let actions = MarkdownTextView.suggestedNextActions(in: blocks)

        #expect(actions.map(\.title) == ["Export a PDF", "Add speaker notes"])
        #expect(actions.map(\.composerText) == ["Export a PDF", "Add speaker notes"])
    }

    @Test("Suggested next actions parse explicit prose suggestions")
    func suggestedNextActionsParseExplicitProseSuggestions() {
        let blocks = MarkdownTextView.parse(
            "Next suggestions: toggle theme via JS, refine contrast for specific components, or change CTA colors."
        )

        let actions = MarkdownTextView.suggestedNextActions(in: blocks)

        #expect(actions.map(\.title) == [
            "toggle theme via JS",
            "refine contrast for specific components",
            "change CTA colors"
        ])
    }

    @Test("Suggested next actions ignore ordinary paragraphs and empty threads")
    func suggestedNextActionsIgnoreOrdinaryParagraphsAndEmptyThreads() {
        let blocks = MarkdownTextView.parse(
            "I can also export a PDF or add speaker notes if that would help."
        )

        #expect(MarkdownTextView.suggestedNextActions(in: blocks).isEmpty)
        #expect(MarkdownTextView.suggestedNextActions(in: []).isEmpty)
    }

    @Test("Parser preserves blockquote paragraph breaks")
    func parserPreservesBlockquoteParagraphBreaks() {
        let blocks = MarkdownTextView.parse("""
        > First quoted paragraph.
        >
        > Second quoted paragraph.
        """)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .blockquote)
        #expect(blocks.first?.content == "First quoted paragraph.\n\nSecond quoted paragraph.")
    }

    @Test("Streaming text normalizes soft wraps")
    func streamingTextNormalizesSoftWraps() {
        let normalized = MarkdownTextView.normalizedStreamingText("""
        First sentence.Second sentence
        continues here.
        """)

        #expect(normalized == "First sentence. Second sentence continues here.")
    }

    @Test("Streaming text preserves markdown tables")
    func streamingTextPreservesMarkdownTables() {
        let normalized = MarkdownTextView.normalizedStreamingText("""
        Progress summary
        | Model/Test | Status |
        |---|---|
        | death | PASS |
        """)

        #expect(normalized.contains("Progress summary\n\n| Model/Test | Status |"))
        #expect(normalized.contains("|---|---|"))
        #expect(normalized.contains("| death | PASS |"))
    }
}

// MARK: - ShelfMarkdownSession

@Suite("ShelfMarkdownSession")
struct ShelfMarkdownSessionTests {

    @MainActor
    @Test("Markdown session store keeps task-pinned sessions separate from shared session")
    func markdownSessionStoreKeepsPinnedSessionsSeparateFromSharedSession() {
        let store = ShelfMarkdownSessionStore()
        let taskID = UUID()

        let shared = store.session(for: nil, pinnedToTask: false)
        let sharedForTask = store.session(for: taskID, pinnedToTask: false)
        let pinned = store.session(for: taskID, pinnedToTask: true)
        let pinnedAgain = store.session(for: taskID, pinnedToTask: true)

        #expect(shared === sharedForTask)
        #expect(shared.boundTaskID == taskID)
        #expect(pinned !== shared)
        #expect(pinned === pinnedAgain)
        #expect(pinned.boundTaskID == taskID)
    }

    @MainActor
    @Test("Opening multiple Markdown files keeps them as selectable tabs")
    func openingMultipleMarkdownFilesKeepsSelectableTabs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-markdown-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let summary = root.appendingPathComponent("summary.md")
        let story = root.appendingPathComponent("warriors_story.md")
        try "# Summary".write(to: summary, atomically: true, encoding: .utf8)
        try "# The Last Quarter".write(to: story, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(summary)
        session.load(story)

        #expect(session.documents.map(\.fileURL) == [summary, story])
        #expect(session.fileURL == story)
        #expect(session.title == "warriors_story.md")
        #expect(session.content.contains("The Last Quarter"))

        session.selectDocument(summary.path)

        #expect(session.fileURL == summary)
        #expect(session.title == "summary.md")
        #expect(session.content.contains("Summary"))

        session.load(story)

        #expect(session.documents.count == 2)
        #expect(session.fileURL == story)
    }

    @MainActor
    @Test("Closing selected Markdown tab selects a neighboring file")
    func closingSelectedMarkdownTabSelectsNeighbor() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-markdown-close-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(first)
        session.load(second)
        session.closeSelectedDocument()

        #expect(session.documents.map(\.fileURL) == [first])
        #expect(session.fileURL == first)

        session.closeSelectedDocument()

        #expect(session.documents.isEmpty)
        #expect(session.fileURL == nil)
        #expect(session.title == "Text")
    }

    @MainActor
    @Test("Copying selected Markdown tab writes content to pasteboard")
    func copyingSelectedMarkdownTabWritesContentToPasteboard() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-markdown-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("story.md")
        try "# Story\n\nFull text".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)
        session.copyContentToPasteboard()

        #expect(NSPasteboard.general.string(forType: .string) == "# Story\n\nFull text")
    }

    @MainActor
    @Test("Saving selected text file persists edits and clears dirty state")
    func savingSelectedTextFilePersistsEditsAndClearsDirtyState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.txt")
        try "first draft".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)

        #expect(session.selectedDocumentKind == .text)
        #expect(session.isSelectedDocumentDirty == false)

        session.updateSelectedContent("final draft\n")

        #expect(session.content == "final draft\n")
        #expect(session.isSelectedDocumentDirty == true)

        session.saveSelectedDocument()

        #expect(try String(contentsOf: file, encoding: .utf8) == "final draft\n")
        #expect(session.isSelectedDocumentDirty == false)
        #expect(session.errorMessage == nil)
    }

    @MainActor
    @Test("Files shelf infers Markdown and JSON document kinds")
    func filesShelfInfersMarkdownAndJSONKinds() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-kinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let quarto = root.appendingPathComponent("report.qmd")
        let json = root.appendingPathComponent("data.json")
        try "# Report".write(to: quarto, atomically: true, encoding: .utf8)
        try #"{"ok":true}"#.write(to: json, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(quarto)
        session.load(json)

        #expect(session.documents.map(\.kind) == [.markdown, .json])
        #expect(session.selectedDocumentKind == .json)
        #expect(session.documents.map(\.title) == ["report.qmd", "data.json"])
        #expect(session.selectedDocument?.formattedJSONContent?.contains(#""ok" : true"#) == true)
        #expect(session.selectedDocument?.jsonErrorMessage == nil)
    }

    @Test("Files shelf syntax highlighting keeps keywords inside strings green")
    func filesShelfSyntaxHighlightingKeepsKeywordsInsideStringsGreen() throws {
        let attributed = ShelfSyntaxHighlighter.attributedString(
            for: #"let phrase = "return 42""#,
            language: .swift
        )
        let keywordRange = (attributed.string as NSString).range(of: "return")
        let numberRange = (attributed.string as NSString).range(of: "42")

        let keywordColor = try #require(attributed.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor)
        let numberColor = try #require(attributed.attribute(.foregroundColor, at: numberRange.location, effectiveRange: nil) as? NSColor)
        #expect(keywordColor.isEqual(NSColor.systemGreen))
        #expect(numberColor.isEqual(NSColor.systemGreen))
    }

    @Test("Files shelf syntax highlighting keeps comment strings in comment color")
    func filesShelfSyntaxHighlightingKeepsCommentStringsInCommentColor() throws {
        let attributed = ShelfSyntaxHighlighter.attributedString(
            for: #"""
            let url = "https://example.com/path"
            // comment says "return 42"
            let value = 1 /* block says 'let' */
            """#,
            language: .swift
        )
        let text = attributed.string as NSString
        let urlRange = text.range(of: "https://example.com/path")
        let lineCommentStringRange = text.range(of: #""return 42""#)
        let blockCommentStringRange = text.range(of: #"'let'"#)

        let urlColor = try #require(attributed.attribute(.foregroundColor, at: urlRange.location, effectiveRange: nil) as? NSColor)
        let lineCommentColor = try #require(attributed.attribute(.foregroundColor, at: lineCommentStringRange.location, effectiveRange: nil) as? NSColor)
        let blockCommentColor = try #require(attributed.attribute(.foregroundColor, at: blockCommentStringRange.location, effectiveRange: nil) as? NSColor)

        #expect(urlColor.isEqual(NSColor.systemGreen))
        #expect(lineCommentColor.isEqual(NSColor.secondaryLabelColor))
        #expect(blockCommentColor.isEqual(NSColor.secondaryLabelColor))
    }

    @Test("Files shelf syntax highlighting skips large files")
    func filesShelfSyntaxHighlightingSkipsLargeFiles() {
        let line = "let value = 42\n"
        let lineCount = (ShelfSyntaxHighlighter.maxHighlightedUTF8Bytes / line.utf8.count) + 2
        let text = String(repeating: line, count: lineCount)
        let attributed = ShelfSyntaxHighlighter.attributedString(for: text, language: .swift)

        var sawNonBaseForeground = false
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let color = value as? NSColor else { return }
            if !color.isEqual(NSColor.labelColor) {
                sawNonBaseForeground = true
            }
        }
        #expect(!sawNonBaseForeground)
    }

    @MainActor
    @Test("Files shelf marks readable large text files before preview")
    func filesShelfMarksLargeReadableTextFilesBeforePreview() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-large-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("large.log")
        let content = String(repeating: "large line\n", count: Int(ShelfMarkdownSession.largeTextPreviewBytes / 10) + 1)
        try content.write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)

        #expect(session.selectedDocumentKind == .text)
        #expect(session.errorMessage == nil)
        #expect(session.content == content)
        #expect(session.selectedDocument?.isLargePreview == true)
        #expect(session.selectedDocument?.fileByteSize ?? 0 >= ShelfMarkdownSession.largeTextPreviewBytes)
    }

    @MainActor
    @Test("Files shelf opens images and binary files as non editable previews")
    func filesShelfOpensImagesAndBinaryFilesAsNonEditablePreviews() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-image-binary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageFile = root.appendingPathComponent("preview.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let pngData = try #require(bitmap?.representation(using: .png, properties: [:]))
        try pngData.write(to: imageFile)

        let binaryFile = root.appendingPathComponent("archive.bin")
        try Data([0, 159, 255, 0]).write(to: binaryFile)

        let session = ShelfMarkdownSession()
        session.load(imageFile)

        #expect(session.selectedDocumentKind == .image)
        #expect(session.selectedDocument?.imageSize.map { Int($0.width) } == 2)
        #expect(session.selectedDocument?.imageSize.map { Int($0.height) } == 1)
        #expect(session.errorMessage == nil)
        #expect(session.canSaveSelectedDocument == false)

        session.load(binaryFile)

        #expect(session.selectedDocumentKind == .unsupported)
        #expect(session.content == "")
        #expect(session.errorMessage == nil)
        #expect(session.canSaveSelectedDocument == false)
    }

    @MainActor
    @Test("Reloading unchanged image file keeps the same preview without publishing")
    func reloadingUnchangedImageFileKeepsSamePreviewWithoutPublishing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-image-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageFile = root.appendingPathComponent("preview.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 3,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let pngData = try #require(bitmap?.representation(using: .png, properties: [:]))
        try pngData.write(to: imageFile)

        let session = ShelfMarkdownSession()
        session.load(imageFile)
        let firstDocument = try #require(session.selectedDocument)
        let firstPreview = try #require(firstDocument.imagePreview)
        var publishCount = 0
        let cancellable = session.objectWillChange.sink { _ in
            publishCount += 1
        }

        withExtendedLifetime(cancellable) {
            session.load(imageFile)
        }

        let reloadedDocument = try #require(session.selectedDocument)
        #expect(publishCount == 0)
        #expect(reloadedDocument.contentSignature == firstDocument.contentSignature)
        #expect(reloadedDocument.imagePreview == firstPreview)
        #expect(reloadedDocument.imageSize.map { Int($0.width) } == 3)
        #expect(reloadedDocument.imageSize.map { Int($0.height) } == 2)
    }

    @MainActor
    @Test("Reloading selected text file discards dirty edits and rereads disk")
    func reloadingSelectedTextFileDiscardsDirtyEditsAndRereadsDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)
        session.updateSelectedContent("unsaved")
        try "changed on disk".write(to: file, atomically: true, encoding: .utf8)

        #expect(session.isSelectedDocumentDirty == true)

        session.reload()

        #expect(session.content == "changed on disk")
        #expect(session.isSelectedDocumentDirty == false)
        #expect(session.saveErrorMessage == nil)
    }

    @MainActor
    @Test("Failed save preserves dirty text and reports save error")
    func failedSavePreservesDirtyTextAndReportsSaveError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-save-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let file = root.appendingPathComponent("notes.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)
        session.updateSelectedContent("unsaved edit")
        try FileManager.default.removeItem(at: root)

        session.saveSelectedDocument()

        #expect(session.content == "unsaved edit")
        #expect(session.isSelectedDocumentDirty == true)
        #expect(session.errorMessage == nil)
        #expect(session.saveErrorMessage?.contains("Could not save notes.txt") == true)

        session.updateSelectedContent("unsaved edit with follow-up")

        #expect(session.saveErrorMessage == nil)
        #expect(session.isSelectedDocumentDirty == true)
    }

    @MainActor
    @Test("Unreadable selected file disables saving")
    func unreadableSelectedFileDisablesSaving() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-missing-text-\(UUID().uuidString).txt")

        let session = ShelfMarkdownSession()
        session.load(file)

        #expect(session.hasFile == true)
        #expect(session.content == "")
        #expect(session.errorMessage?.contains("Could not read") == true)
        #expect(session.canSaveSelectedDocument == false)
        #expect(session.isSelectedDocumentDirty == false)
    }
}

// MARK: - ShelfBrowserSession lazy WebKit

@Suite("ShelfBrowserSession lazy WebKit")
@MainActor
struct ShelfBrowserSessionLazyWebKitTests {
    @Test("A freshly created session has not instantiated WebKit")
    func freshSessionDoesNotLoadWebKit() {
        let session = ShelfBrowserSession()
        defer { session.teardown() }
        // The fix: constructing a session (which happens at app launch for the
        // off-screen browser shelf) must NOT spin up WebKit — doing so pulls in
        // the Photos/Music frameworks and triggers media-library TCC prompts at
        // startup. WebKit must wait until the browser is actually shown.
        #expect(session.isWebViewLoaded == false)
    }

    @Test("Accessing webView creates it on demand")
    func accessingWebViewCreatesItOnDemand() {
        let session = ShelfBrowserSession()
        defer { session.teardown() }
        _ = session.webView
        #expect(session.isWebViewLoaded == true)
    }
}
