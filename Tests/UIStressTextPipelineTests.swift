import Testing
import Foundation
import ASTRACore
@testable import ASTRA

/// Stress tests for the chat text pipeline: `MarkdownRenderPreparation`,
/// `TaskRunAnswerPresentationPolicy`, `AgentEventRecordingPresentation`, and
/// the `MarkdownTextView` parse path. These target the exact code that runs on
/// every streamed chunk and every rendered bubble, so pathological provider
/// output (huge single lines, fence storms, envelope re-sends, unicode soup)
/// must stay linear-ish and must never corrupt code blocks.
///
/// Time budgets are deliberately loose (an order of magnitude over local
/// measurements) so they only trip on complexity blowups, not machine noise.
/// The `RUN_UI_STRESS=1` tier scales the same shapes up far enough that a
/// quadratic implementation visibly separates from a linear one.
@Suite("UI stress: text pipeline")
struct UIStressTextPipelineTests {
    private static let heavyTierEnabled = ProcessInfo.processInfo.environment["RUN_UI_STRESS"] != nil

    // MARK: - Fixtures

    /// Deterministic RNG so every stress run exercises the identical byte stream.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static func mixedMarkdownDocument(paragraphs: Int) -> String {
        var rng = SplitMix64(state: 0xA57A_0001)
        var parts: [String] = []
        parts.reserveCapacity(paragraphs)
        for index in 0..<paragraphs {
            switch index % 6 {
            case 0:
                parts.append("## Section \(index)\nBody text for section \(index) with `inline code` and a [link](https://example.com/\(index)).")
            case 1:
                parts.append("| Name | Value |\n| --- | --- |\n| row\(index) | \(rng.next() % 1_000) |\n| other | \(rng.next() % 1_000) |")
            case 2:
                parts.append("```swift\nlet value\(index) = compute(\(index))\nprint(value\(index))\n```")
            case 3:
                parts.append("- item one for block \(index)\n- item two for block \(index)\n- item three for block \(index)")
            case 4:
                parts.append("Plain paragraph \(index) that is long enough to look like real prose from a provider, mentioning file\(index).swift and a value of \(rng.next() % 100_000).")
            default:
                parts.append("> Quoted note \(index) with trailing detail.")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// A single line with many glued numbered markers — exactly the shape
    /// `reflowInlineBlockMarkers` exists to repair. The split heuristic only
    /// follows consecutive numbers up to two digits, so `items` must stay
    /// below 100 for the split-count assertions.
    private static func gluedMarkerLine(items: Int) -> String {
        var line = "Deployment steps: 1. Prepare the environment carefully."
        for index in 2...items {
            line += " \(index). Run step number \(index) with `cmd-\(index)` and confirm the output looks right."
        }
        return line
    }

    /// Dash-bullet runs have no numeric sequence gate, so they scale to
    /// arbitrary marker counts — the shape for probing per-marker rescans.
    private static func gluedBulletLine(items: Int) -> String {
        var line = "Observed calls:"
        for index in 1...items {
            line += " - endpoint `/api/v\(index)` returned status \(200 + index % 3) in a reasonable time"
        }
        return line
    }

    private static func gluedHeadingLine(headings: Int) -> String {
        var line = "Overview of the run follows."
        for index in 1...headings {
            line += " ## Heading \(index) With `span \(index)` and prose tail number \(index)."
        }
        return line
    }

    // MARK: - prepareForDisplay scale + idempotence

    @Test("prepareForDisplay stays fast on a large mixed document")
    func prepareForDisplayLargeMixedDocument() {
        let document = Self.mixedMarkdownDocument(paragraphs: 3_000)
        #expect(document.utf8.count > 200_000)

        var prepared = ""
        let elapsed = ContinuousClock().measure {
            prepared = MarkdownRenderPreparation.prepareForDisplay(document)
        }
        #expect(!prepared.isEmpty)
        // Locally ~60ms; only a complexity blowup should cross this.
        #expect(elapsed < .seconds(3), "prepareForDisplay took \(elapsed) for \(document.utf8.count) bytes")
    }

    @Test("prepareForDisplay is idempotent across adversarial documents")
    func prepareForDisplayIsIdempotent() {
        let corpus: [String] = [
            Self.mixedMarkdownDocument(paragraphs: 200),
            Self.gluedMarkerLine(items: 40),
            Self.gluedHeadingLine(headings: 30),
            "Intro: - alpha item body - beta item body - gamma item body",
            "## Title | Col A | Col B |\n| --- | --- |\n| 1 | 2 |",
            "```\ncode with | pipes | inside\n```\n| a | b |\n| --- | --- |",
            "Line one\r\nLine two\rLine three\n\n\n\n\nLine four",
            "prose ## Not A Heading because lowercase tail follows here",
            String(repeating: "- item\n", count: 500),
            String(repeating: "> depth\n", count: 300)
        ]
        for (index, document) in corpus.enumerated() {
            let once = MarkdownRenderPreparation.prepareForDisplay(document)
            let twice = MarkdownRenderPreparation.prepareForDisplay(once)
            #expect(twice == once, "prepareForDisplay not idempotent for corpus[\(index)]")
        }
    }

    @Test("blank-line collapse survives a 50k blank-line flood quickly")
    func blankLineFloodStaysBounded() {
        let flood = "start" + String(repeating: "\n", count: 50_000) + "end"
        var prepared = ""
        let elapsed = ContinuousClock().measure {
            prepared = MarkdownRenderPreparation.prepareForDisplay(flood)
        }
        #expect(prepared == "start\n\nend")
        #expect(elapsed < .seconds(2))
    }

    // MARK: - Fence integrity

    /// `reflowInlineBlockMarkers` tracks fences with CommonMark semantics
    /// (character + run length), but `repairBlockBoundaries` toggles on any
    /// ```/~~~ prefix. A ``` line inside a ```` fence therefore flips the two
    /// passes into disagreeing states, and the repair pass injects blank
    /// lines into fenced content it believes is a table.
    @Test("shorter fence runs inside a longer fence do not corrupt fenced content")
    func nestedFenceRunsKeepFencedContentIntact() {
        let fenced = [
            "````",
            "```",
            "| left | right |",
            "| --- | --- |",
            "| a | b |",
            "````"
        ].joined(separator: "\n")

        let prepared = MarkdownRenderPreparation.prepareForDisplay(fenced)
        let interior = prepared
            .components(separatedBy: "\n")
            .dropFirst()
            .dropLast()
        withKnownIssue(
            "repairBlockBoundaries toggles fence state on any ```/~~~ prefix, so a ``` line inside a ```` fence drops it out of code mode and table repair inserts blank lines into fenced content"
        ) {
            #expect(
                !interior.contains(""),
                "blank lines were injected inside a fenced block: \(prepared)"
            )
        }
    }

    @Test("an unterminated fence followed by table chunks keeps streaming stable")
    func unterminatedFenceWithTableChunks() {
        let chunks = [
            "Here is the diff:\n```diff",
            "+ added line one",
            "| not | a | table |",
            "+ added line two"
        ]
        let joined = MarkdownRenderPreparation.joinChunks(chunks)
        // Everything after the opener is fenced content: the pipe line must not
        // acquire table blank-line padding.
        #expect(joined.contains("+ added line one\n| not | a | table |\n+ added line two"))
    }

    // MARK: - joinChunks scale + seam correctness

    @Test("joinChunks handles thousands of streamed chunks within budget")
    func joinChunksManyChunks() {
        var rng = SplitMix64(state: 0xA57A_0002)
        var chunks: [String] = []
        chunks.reserveCapacity(4_000)
        for index in 0..<4_000 {
            switch rng.next() % 4 {
            case 0: chunks.append("word\(index)")
            case 1: chunks.append("Sentence number \(index) ends here.")
            case 2: chunks.append("- bullet \(index)")
            default: chunks.append("tail fragment \(index)")
            }
        }
        var joined = ""
        let elapsed = ContinuousClock().measure {
            joined = MarkdownRenderPreparation.joinChunks(chunks, prepareForDisplay: false)
        }
        #expect(joined.utf8.count > 40_000)
        // Locally ~80ms; guards against a quadratic accumulate-and-rescan.
        #expect(elapsed < .seconds(4), "joinChunks took \(elapsed) for \(chunks.count) chunks")
    }

    @Test("length-capped storage cuts rejoin mid-word without inventing a space")
    func coalescingCutRejoinsMidWord() {
        let cap = TaskRunAnswerPresentationPolicy.conversationChunkCoalescingCap
        let head = String(repeating: "x", count: cap - 7) + " consid"
        #expect(head.count >= cap - 64, "fixture must land within the cut margin")
        let joined = MarkdownRenderPreparation.joinChunks(
            [head, "eration continues here."],
            prepareForDisplay: false,
            coalescingCapHint: cap
        )
        #expect(joined.contains("consideration continues here."))
    }

    @Test("chunks not at the cap still get a separating space")
    func nonCutChunksKeepSeparator() {
        let joined = MarkdownRenderPreparation.joinChunks(
            ["First sentence ends", "and this continues."],
            prepareForDisplay: false,
            coalescingCapHint: TaskRunAnswerPresentationPolicy.conversationChunkCoalescingCap
        )
        #expect(joined == "First sentence ends and this continues.")
    }

    // MARK: - Glued-marker reflow scale (quadratic probe)

    @Test("glued numbered-list reflow splits consecutively numbered runs")
    func gluedListReflowModerate() {
        let line = Self.gluedMarkerLine(items: 80)
        var prepared = ""
        let elapsed = ContinuousClock().measure {
            prepared = MarkdownRenderPreparation.prepareForDisplay(line)
        }
        #expect(prepared.components(separatedBy: "\n").count > 60, "marker run should split into list lines")
        #expect(elapsed < .seconds(2), "reflow took \(elapsed) for \(line.utf8.count) bytes")
    }

    @Test("numbered-list recovery stops at the two-digit heuristic ceiling")
    func gluedListReflowStopsAtTwoDigits() {
        // Documents the deliberate `\d{1,2}` bound in listRunSplit: items
        // beyond 99 stay glued to item 99's line. A glued 200-step provider
        // answer therefore renders its tail as one long paragraph — see the
        // findings report.
        let line = Self.gluedMarkerLine(items: 150)
        let prepared = MarkdownRenderPreparation.prepareForDisplay(line)
        let lines = prepared.components(separatedBy: "\n")
        #expect(lines.count == 100, "splitting is expected to stop after item 99, got \(lines.count) lines")
    }

    @Test("glued bullet-run reflow on a long single line stays bounded")
    func gluedBulletReflowModerate() {
        let line = Self.gluedBulletLine(items: 500)
        var prepared = ""
        let elapsed = ContinuousClock().measure {
            prepared = MarkdownRenderPreparation.prepareForDisplay(line)
        }
        #expect(prepared.components(separatedBy: "\n").count > 400, "bullet run should split into list lines")
        // Locally ~10ms. A per-match inline-code rescan is quadratic in the
        // marker count and blows through this at stress sizes first.
        #expect(elapsed < .seconds(2), "reflow took \(elapsed) for \(line.utf8.count) bytes")
    }

    @Test(
        "heavy tier: glued bullet and heading reflow at thousands of markers on one line",
        .enabled(if: heavyTierEnabled, "Set RUN_UI_STRESS=1 to run heavy UI stress tiers")
    )
    func gluedReflowHeavy() {
        let bulletLine = Self.gluedBulletLine(items: 6_000)
        let headingLine = Self.gluedHeadingLine(headings: 3_000)
        let clock = ContinuousClock()
        let bulletElapsed = clock.measure {
            _ = MarkdownRenderPreparation.prepareForDisplay(bulletLine)
        }
        let headingElapsed = clock.measure {
            _ = MarkdownRenderPreparation.prepareForDisplay(headingLine)
        }
        // A linear pass over ~500KB is a few ms; a per-match rescan from the
        // line start is tens of billions of character reads.
        #expect(bulletElapsed < .seconds(5), "bullet reflow took \(bulletElapsed) for \(bulletLine.utf8.count) bytes")
        #expect(headingElapsed < .seconds(5), "heading reflow took \(headingElapsed) for \(headingLine.utf8.count) bytes")
    }

    // MARK: - Answer presentation: code preservation

    @Test("sentence-spacing normalization must not edit fenced code")
    func fencedCodeSurvivesSentenceSpacing() {
        let raw = [
            "Here is the fix.The code follows:",
            "",
            "```swift",
            "let handler = Foo.Bar()",
            "queue.async { handler.run(mode:.Fast) }",
            "```"
        ].joined(separator: "\n")

        let presentation = TaskRunAnswerPresentationPolicy.presentation(rawText: raw)
        withKnownIssue(
            "normalizedVisibleText applies the ([.!?])([A-Z`#]) sentence-spacing regex to the whole payload before fence-aware preparation, so code like Foo.Bar() gains an interior space"
        ) {
            #expect(presentation.answerText.contains("Foo.Bar()"), "fenced code was rewritten: \(presentation.answerText)")
            #expect(presentation.answerText.contains("mode:.Fast"))
        }
        // The prose seam outside the fence SHOULD gain its space.
        #expect(presentation.answerText.contains("fix. The code follows"))
    }

    @Test("adjacent-line dedupe must not swallow repeated closing braces")
    func closingBracesSurviveLineDedupe() {
        // No blank lines anywhere: the dedupe runs at the line tier, where the
        // whitespace-collapsed comparison key of "    }" and "}" is identical.
        let raw = [
            "```swift",
            "func outer() {",
            "    if condition {",
            "        act()",
            "    }",
            "}",
            "```"
        ].joined(separator: "\n")

        let presentation = TaskRunAnswerPresentationPolicy.presentation(rawText: raw)
        let closingBraceLines = presentation.answerText
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "}" }
        withKnownIssue(
            "dedupeAdjacentSegments keys on whitespace-collapsed lines, so consecutive closing braces at different indentation collapse into one"
        ) {
            #expect(closingBraceLines.count == 2, "expected both closing braces, got: \(presentation.answerText)")
        }
    }

    @Test("identical adjacent paragraphs inside one fence are preserved")
    func repeatedFencedStanzasSurviveParagraphDedupe() {
        // The repeated stanza must form two standalone, identical paragraphs
        // strictly inside the fence (header/footer keep the fence markers out
        // of the compared segments).
        let stanza = "server:\n  retries: 3\n  timeout: 30"
        let raw = "Config follows:\n\n```yaml\nregion: us-west\n\n\(stanza)\n\n\(stanza)\n\nreplicas: 2\n```"
        let presentation = TaskRunAnswerPresentationPolicy.presentation(rawText: raw)
        let occurrences = presentation.answerText.components(separatedBy: "retries: 3").count - 1
        withKnownIssue(
            "paragraph-tier dedupe treats blank-line-separated identical stanzas inside a fence as duplicate segments and drops the second"
        ) {
            #expect(occurrences == 2, "expected both YAML stanzas, got: \(presentation.answerText)")
        }
    }

    // MARK: - Answer presentation: pathological input battery

    @Test(
        "presentation survives hostile encodings",
        arguments: [
            "emoji 👩‍👩‍👧‍👦🏳️‍🌈 and ZWJ\u{200D} sequences repeated 🧵🧵🧵.",
            "RTL: مرحبا بالعالم mixed with LTR and \u{200F} marks.",
            "combining: a\u{0301}e\u{0301}i\u{0301}o\u{0301}u\u{0301} everywhere",
            "control: bell\u{07} nul\u{00} backspace\u{08} escape\u{1B}[31mred\u{1B}[0m",
            "zero-width: a\u{200B}b\u{200B}c spaced\u{00A0}nbsp",
            "crlf: one\r\ntwo\rthree\nfour"
        ]
    )
    func presentationSurvivesHostileEncodings(hostile: String) {
        let raw = String(repeating: hostile + " tail marker.\n", count: 50)
        var presentation: TaskRunAnswerPresentation?
        let elapsed = ContinuousClock().measure {
            presentation = TaskRunAnswerPresentationPolicy.presentation(rawText: raw)
        }
        #expect(presentation?.answerText.isEmpty == false)
        #expect(presentation?.rawText == raw)
        #expect(elapsed < .seconds(2))
    }

    @Test("summaryText stays bounded and non-crashing on huge unstructured input")
    func summaryTextBoundedOnHugeInput() {
        let huge = String(repeating: "wordsoup ", count: 120_000)
        let summary = TaskRunAnswerPresentationPolicy.summaryText(rawText: huge, maxLength: 280)
        #expect(summary.count <= 284, "summary must respect maxLength plus ellipsis")
    }

    @Test("joinedResponsePayloads strips protocol markers across 2k payloads")
    func joinedResponsePayloadsStripsMarkersAtScale() {
        var payloads: [String] = []
        for index in 0..<2_000 {
            payloads.append("ASTRA_EVENT progress \(index)\nvisible \(index).")
        }
        var joined = ""
        let elapsed = ContinuousClock().measure {
            joined = TaskRunAnswerPresentationPolicy.joinedResponsePayloads(payloads)
        }
        #expect(!joined.contains("ASTRA_EVENT"))
        #expect(joined.contains("visible 0."))
        #expect(joined.contains("visible 1999."))
        #expect(elapsed < .seconds(6), "joinedResponsePayloads took \(elapsed)")
    }

    // MARK: - Streamed-delta echo dedupe

    @Test("envelope re-send dedupe stays bounded across a long streamed run")
    func envelopeEchoDedupeModerate() {
        var output = ""
        var appended = 0
        let elapsed = ContinuousClock().measure {
            for index in 0..<150 {
                let delta = "Progress line \(index) with enough characters to look like a realistic streamed sentence.\n"
                output += AgentEventRecordingPresentation.responseTextToAppend(delta, after: output)
                // The provider re-sends the whole envelope with INTERIOR
                // whitespace shifted, which defeats the cheap trimmed-equality
                // branch and forces the collapse-the-whole-output fallback.
                let envelope = output.replacingOccurrences(of: "\n", with: " \n")
                let echoAppend = AgentEventRecordingPresentation.responseTextToAppend(envelope, after: output)
                if !echoAppend.isEmpty { appended += 1 }
            }
        }
        #expect(appended == 0, "whitespace-shifted envelope echoes must never re-append")
        // Locally ~120ms; the fallback collapses the whole output per delta,
        // so a regression here compounds fast.
        #expect(elapsed < .seconds(4), "echo dedupe took \(elapsed) for \(output.utf8.count) bytes of output")
    }

    @Test(
        "heavy tier: envelope re-send dedupe at 800 ticks",
        .enabled(if: heavyTierEnabled, "Set RUN_UI_STRESS=1 to run heavy UI stress tiers")
    )
    func envelopeEchoDedupeHeavy() {
        var output = ""
        let elapsed = ContinuousClock().measure {
            for index in 0..<800 {
                let delta = "Streamed sentence \(index) carrying a realistic amount of prose per tick for the run.\n"
                output += AgentEventRecordingPresentation.responseTextToAppend(delta, after: output)
                let envelope = output.replacingOccurrences(of: "\n", with: " \n")
                _ = AgentEventRecordingPresentation.responseTextToAppend(envelope, after: output)
            }
        }
        #expect(output.utf8.count > 60_000)
        #expect(elapsed < .seconds(10), "echo dedupe took \(elapsed) for \(output.utf8.count) bytes")
    }

    @Test("a genuine long repeat that matches earlier output is treated as an echo")
    func genuineLongRepeatIsSwallowedByEchoHeuristic() {
        // Documents the deliberate trade-off in responseTextToAppend: any
        // ≥80-char chunk whose collapsed text already appears in the output is
        // dropped, even if the agent legitimately repeats itself. If this
        // starts failing, the heuristic changed and the findings report entry
        // should be revisited.
        let sentence = "The deployment completed successfully and all twelve health checks passed on the first attempt."
        let existing = "Earlier: \(sentence)\nMore detail followed."
        let appended = AgentEventRecordingPresentation.responseTextToAppend(sentence, after: existing)
        #expect(appended.isEmpty, "current heuristic swallows legitimate ≥80-char repeats")
    }

    // MARK: - Full parse path (MarkdownTextView.parse)

    @Test("full markdown parse of a large document stays within budget")
    func fullParseLargeDocument() {
        let document = Self.mixedMarkdownDocument(paragraphs: 1_200)
        var blocks: [MarkdownTextView.MarkdownBlock] = []
        let elapsed = ContinuousClock().measure {
            blocks = MarkdownTextView.parse(document)
        }
        #expect(blocks.count > 1_000)
        // This is the exact work MarkdownTextView.init does on the main
        // thread per bubble; locally ~200ms at this size.
        #expect(elapsed < .seconds(5), "parse took \(elapsed) for \(document.utf8.count) bytes")
    }

    @Test("parse survives a 5k-row table and deep blockquote nesting")
    func parsePathologicalStructures() {
        var table = "| a | b |\n| --- | --- |\n"
        for index in 0..<5_000 {
            table += "| cell \(index) | value \(index) |\n"
        }
        let quotes = String(repeating: "> ", count: 200) + "deep quote"
        let clock = ContinuousClock()
        let tableElapsed = clock.measure { _ = MarkdownTextView.parse(table) }
        let quoteElapsed = clock.measure { _ = MarkdownTextView.parse(quotes) }
        #expect(tableElapsed < .seconds(5), "table parse took \(tableElapsed)")
        #expect(quoteElapsed < .seconds(2), "blockquote parse took \(quoteElapsed)")
    }

    @Test("parse of an unterminated fence flood does not hang")
    func parseUnterminatedFenceFlood() {
        let flood = "```\n" + String(repeating: "line of code content\n", count: 20_000)
        var blocks: [MarkdownTextView.MarkdownBlock] = []
        let elapsed = ContinuousClock().measure {
            blocks = MarkdownTextView.parse(flood)
        }
        #expect(!blocks.isEmpty)
        #expect(elapsed < .seconds(5), "unterminated fence parse took \(elapsed)")
    }
}
