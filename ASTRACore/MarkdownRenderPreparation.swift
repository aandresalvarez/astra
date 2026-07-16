import Foundation

public enum MarkdownRenderPreparation {
    public static func prepareForDisplay(_ text: String) -> String {
        let normalized = normalizedLineEndings(text)
        let reflowed = reflowInlineBlockMarkers(in: normalized)
        return repairBlockBoundaries(in: reflowed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// - Parameter coalescingCapHint: The storage layer's per-row coalescing
    ///   cap (e.g. `TaskRunAnswerPresentationPolicy.conversationChunkCoalescingCap`),
    ///   if the chunks came from such rows. When set, a chunk whose length
    ///   lands near the cap is treated as a pure length cut rather than a
    ///   semantic gap -- see `wasCoalescingCut`. Omit for chunks with no such
    ///   storage boundary (the seam heuristics fall back to their prior,
    ///   content-only behavior).
    public static func joinChunks(
        _ chunks: [String],
        prepareForDisplay: Bool = true,
        coalescingCapHint: Int? = nil
    ) -> String {
        var joined = ""
        var currentLastNonEmptyLine: String?
        var hasUnclosedFence = false
        var previousChunkLength: Int?

        for rawChunk in chunks {
            let chunk = normalizedLineEndings(rawChunk)
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if joined.isEmpty {
                joined = chunk
            } else {
                joined += separatorBetween(
                    leftText: joined,
                    leftLastNonEmptyLine: currentLastNonEmptyLine,
                    leftHasUnclosedFence: hasUnclosedFence,
                    leftWasCoalescingCut: wasCoalescingCut(previousChunkLength: previousChunkLength, capHint: coalescingCapHint),
                    rightText: chunk
                ) + chunk
            }
            currentLastNonEmptyLine = lastNonEmptyLine(in: chunk) ?? currentLastNonEmptyLine
            hasUnclosedFence.toggle(ifOdd: fenceLineCount(in: chunk))
            previousChunkLength = rawChunk.count
        }

        return prepareForDisplay ? self.prepareForDisplay(joined) : joined
    }

    /// Margin below `capHint` still treated as "cut by the cap". Real
    /// streaming deltas are far smaller than the cap, so a row closed by an
    /// unrelated event (not the length check) would only land this close to
    /// it by coincidence -- this stays a precise signal without needing to
    /// track the actual close reason.
    private static let coalescingCutMargin = 64

    private static func wasCoalescingCut(previousChunkLength: Int?, capHint: Int?) -> Bool {
        guard let capHint, let previousChunkLength else { return false }
        return previousChunkLength >= capHint - coalescingCutMargin
    }

    private static func repairBlockBoundaries(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var fenceTracker = MarkdownFenceTracker()
        var isInsideTable = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            let isProtectedByFence = fenceTracker.protects(line)
            if isFenceLine(trimmed) {
                appendBlankIfNeeded(afterTable: &isInsideTable, output: &output)
                output.append(line)
                index += 1
                continue
            }

            if isProtectedByFence {
                output.append(line)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                output.append(line)
                isInsideTable = false
                index += 1
                continue
            }

            if let split = splitHeadingAndTableHeader(line, nextLine: nextNonEmptyLine(after: index, in: lines)) {
                appendBlankIfNeeded(afterTable: &isInsideTable, output: &output)
                output.append(split.heading)
                appendBlankIfNeeded(output: &output)
                output.append(split.tableHeader)
                isInsideTable = true
                index += 1
                continue
            }

            let isTableLine = shouldTreatAsTableLine(
                line,
                nextLine: nextNonEmptyLine(after: index, in: lines),
                isInsideTable: isInsideTable
            )

            if isTableLine {
                if !isInsideTable {
                    appendBlankIfNeeded(output: &output)
                }
                output.append(line)
                isInsideTable = true
                index += 1
                continue
            }

            appendBlankIfNeeded(afterTable: &isInsideTable, output: &output)
            output.append(line)
            index += 1
        }

        return collapseExtraBlankLines(output.joined(separator: "\n"))
    }

    // MARK: - Inline block-marker reflow

    /// Providers occasionally deliver markdown with block markers glued
    /// mid-line ("…calls: - `a` → GET - `b` → POST … ### 3. Installed …").
    /// Line-oriented block parsing can only recover structure from markers at
    /// line starts, so reflow the unambiguous glue patterns onto their own
    /// lines: mid-line `##`+ headings, colon-introduced bullet runs, and
    /// colon-introduced numbered sequences. Fenced code is never touched.
    static func reflowInlineBlockMarkers(in text: String) -> String {
        var output: [String] = []
        var fenceTracker = MarkdownFenceTracker()

        for line in text.components(separatedBy: "\n") {
            if fenceTracker.protects(line) {
                output.append(line)
                continue
            }
            // Markdown's indented code blocks (4 spaces / tab) are code too;
            // reflowing them would turn a snippet into prose plus list items
            // and destroy its indentation.
            if isIndentedCodeLine(line) {
                output.append(line)
                continue
            }
            output.append(contentsOf: reflowedLine(line))
        }

        return output.joined(separator: "\n")
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func reflowedLine(_ line: String) -> [String] {
        guard line.contains("## ") || line.contains(": ")
            || firstMatchRange(#"^\s*1[.)]\s"#, in: line) != nil else {
            return [line]
        }
        let headingChunks = headingSplit(line)
        var lines: [String] = []
        for (index, chunk) in headingChunks.enumerated() {
            let isRecoveredHeading = isSpacedHeading(chunk) && (headingChunks.count > 1 || index > 0)
            for piece in headingRemainderCut(chunk, isRecoveredHeading: isRecoveredHeading) {
                lines.append(contentsOf: listRunSplit(piece))
            }
        }
        return lines
    }

    /// Splits a line before every mid-line `##`–`######` run that is preceded
    /// by whitespace and followed by spaced, capitalized-or-numbered content.
    /// Single `#` is left alone ("issue # 5" must not become a heading), and
    /// the content gate keeps prose mentions of hash syntax intact ("C macros
    /// use ## token pasting" — lowercase continuation, not a heading).
    private static func headingSplit(_ line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<=\s)#{2,6}\s+(?=[A-Z0-9])"#) else { return [line] }
        let nsLine = line as NSString
        let candidates = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !candidates.isEmpty else { return [line] }
        let codeSpans = InlineCodeSpanIndex(nsLine)
        let matches = candidates.filter { !codeSpans.contains($0.range.location) }
        guard !matches.isEmpty else { return [line] }

        var chunks: [String] = []
        var start = 0
        for match in matches {
            let head = nsLine.substring(with: NSRange(location: start, length: match.range.location - start))
                .trimmingCharacters(in: .whitespaces)
            if !head.isEmpty {
                chunks.append(head)
            }
            start = match.range.location
        }
        let tail = nsLine.substring(from: start).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            chunks.append(tail)
        }
        return chunks.isEmpty ? [line] : chunks
    }

    /// A marker only counts as glued-list evidence when a substantial block
    /// follows it; a short tail ("- macOS setup", "1. Setup") is far more
    /// likely the heading's own punctuation than a dragged list item.
    private static let headingRemainderCutMinimumTail = 24

    /// A heading recovered from mid-line glue frequently drags trailing list
    /// items with it ("### Title * Overwrote …"). Cut the heading before the
    /// first embedded list marker so the remainder renders as its own block.
    /// Pristine heading lines (single chunk at line start) are never cut.
    private static func headingRemainderCut(_ chunk: String, isRecoveredHeading: Bool) -> [String] {
        guard isRecoveredHeading,
              let regex = try? NSRegularExpression(pattern: #"\s(?:[-*+]|\d{1,2}[.)])\s"#) else {
            return [chunk]
        }
        let nsChunk = chunk as NSString
        let matches = regex.matches(in: chunk, range: NSRange(location: 0, length: nsChunk.length))
        guard !matches.isEmpty else { return [chunk] }
        let codeSpans = InlineCodeSpanIndex(nsChunk)
        for match in matches where !codeSpans.contains(match.range.location) {
            let heading = nsChunk.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            let remainder = nsChunk.substring(from: match.range.location).trimmingCharacters(in: .whitespaces)
            // The first marker can sit inside the heading's own numbering
            // ("### 3. Title * item" matches at " 3. " first); keep scanning
            // until the prefix is a well-formed heading with a real block
            // trailing it.
            guard isSpacedHeading(heading), remainder.count >= headingRemainderCutMinimumTail else { continue }
            return [heading, remainder]
        }
        return [chunk]
    }

    /// Breaks marker runs onto their own lines when the run is unambiguous:
    /// colon-introduced dash bullets ("calls: - `a` → GET - `b` → POST"),
    /// colon-introduced numbered steps ("steps: 1. Open app. 2. Go to …"),
    /// and lines that already start with "1." and glue the later numbers.
    /// Only `-` opens a colon bullet run: `*` after a colon is routinely a
    /// cron wildcard or multiplication ("Schedule: * * * * *"), and prose
    /// hyphens ("state - of - the - art") never match a trigger. A trigger
    /// found inside an inline code span is no trigger at all.
    private static func listRunSplit(_ chunk: String) -> [String] {
        let nsChunk = chunk as NSString
        let codeSpans = InlineCodeSpanIndex(nsChunk)
        if let bulletTrigger = firstMatchRange(#":\s+-\s"#, in: chunk),
           !codeSpans.contains(bulletTrigger.location) {
            return splitMarkerRun(
                chunk,
                codeSpans: codeSpans,
                markerPattern: #"\s-\s+"#,
                searchStart: bulletTrigger.location + 1,
                firstExpectedNumber: nil,
                minimumItemLength: bulletRunMinimumItemLength
            )
        }
        if let numberTrigger = firstMatchRange(#":\s+1[.)]\s"#, in: chunk),
           !codeSpans.contains(numberTrigger.location) {
            return splitMarkerRun(
                chunk,
                codeSpans: codeSpans,
                markerPattern: #"\s\d+[.)]\s+"#,
                searchStart: numberTrigger.location + 1,
                firstExpectedNumber: 1
            )
        }
        if let leadingNumber = firstMatchRange(#"^\s*1[.)]\s"#, in: chunk) {
            return splitMarkerRun(
                chunk,
                codeSpans: codeSpans,
                markerPattern: #"\s\d+[.)]\s+"#,
                searchStart: leadingNumber.location + leadingNumber.length - 1,
                firstExpectedNumber: 2
            )
        }
        return [chunk]
    }

    /// A dash run only splits when every resulting item is substantial; prose
    /// hyphens inside a genuine item ("- supports state - of - the - art
    /// layouts") produce stub pieces and cancel the whole split rather than
    /// corrupting the sentence.
    private static let bulletRunMinimumItemLength = 10

    private static func splitMarkerRun(
        _ chunk: String,
        codeSpans: InlineCodeSpanIndex,
        markerPattern: String,
        searchStart: Int,
        firstExpectedNumber: Int?,
        minimumItemLength: Int? = nil
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return [chunk] }
        let nsChunk = chunk as NSString
        guard searchStart < nsChunk.length else { return [chunk] }
        let searchRange = NSRange(location: searchStart, length: nsChunk.length - searchStart)
        let matches = regex.matches(in: chunk, range: searchRange)
        guard !matches.isEmpty else { return [chunk] }

        var breakPoints: [Int] = []
        var expectedNumber = firstExpectedNumber
        for match in matches {
            guard !codeSpans.contains(match.range.location) else { continue }
            if let expected = expectedNumber {
                let markerText = nsChunk.substring(with: match.range)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
                guard Int(markerText) == expected else { continue }
                expectedNumber = expected + 1
            }
            breakPoints.append(match.range.location)
        }
        guard !breakPoints.isEmpty else { return [chunk] }

        var lines: [String] = []
        var start = 0
        for point in breakPoints {
            let piece = nsChunk.substring(with: NSRange(location: start, length: point - start))
                .trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty {
                lines.append(piece)
            }
            start = point
        }
        let tail = nsChunk.substring(from: start).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            lines.append(tail)
        }
        if let minimumItemLength,
           lines.dropFirst().contains(where: { $0.count < minimumItemLength }) {
            return [chunk]
        }
        return lines.isEmpty ? [chunk] : lines
    }

    /// A marker inside a CommonMark inline code span must not be treated as
    /// list/heading glue. Spans are delimited by matching backtick RUNS
    /// (`` `code` ``, ```` ``code`` ````), so simple odd/even parity fails for
    /// double-backtick spans; walk the runs and track the open span length.
    /// The splitting helpers ask about one location per regex match —
    /// thousands on a marker-dense line — so re-walking the runs per query
    /// would be quadratic. One forward pass records the offset of every run
    /// that opens or closes a span; a location is inside a span exactly when
    /// an odd number of those flips precede it.
    private struct InlineCodeSpanIndex {
        /// Ascending UTF-16 offsets of runs that flipped the span state.
        private let flipLocations: [Int]

        init(_ text: NSString) {
            var flips: [Int] = []
            var index = 0
            var openRunLength = 0
            let length = text.length
            while index < length {
                guard text.character(at: index) == 0x60 else {
                    index += 1
                    continue
                }
                var runEnd = index
                while runEnd < length, text.character(at: runEnd) == 0x60 {
                    runEnd += 1
                }
                let runLength = runEnd - index
                if openRunLength == 0 {
                    openRunLength = runLength
                    flips.append(index)
                } else if runLength == openRunLength {
                    // Only a run of the exact opening length closes the span.
                    openRunLength = 0
                    flips.append(index)
                }
                index = runEnd
            }
            flipLocations = flips
        }

        /// Whether `location` falls inside an open span. Flips strictly
        /// before `location` alternate open/close, so an odd count means
        /// open. A run straddling `location` counts in full — its flip sits
        /// at the run's start — matching a sequential scan that consumes
        /// whole runs.
        func contains(_ location: Int) -> Bool {
            var low = 0
            var high = flipLocations.count
            while low < high {
                let mid = (low + high) / 2
                if flipLocations[mid] < location {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low % 2 == 1
        }
    }

    private static func firstMatchRange(_ pattern: String, in text: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))?.range
    }

    private static func shouldTreatAsTableLine(
        _ line: String,
        nextLine: String?,
        isInsideTable: Bool
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if isTableSeparator(trimmed) {
            return true
        }
        guard isTableRow(trimmed) else { return false }
        if isInsideTable {
            return true
        }
        guard let nextLine else { return false }
        return isTableSeparator(nextLine.trimmingCharacters(in: .whitespaces))
    }

    private static func separatorBetween(
        leftText: String,
        leftLastNonEmptyLine: String?,
        leftHasUnclosedFence: Bool,
        leftWasCoalescingCut: Bool,
        rightText: String
    ) -> String {
        let rhsFirstLine = firstNonEmptyLine(in: rightText)

        if leftHasUnclosedFence {
            return leftText.hasSuffix("\n") ? "" : "\n"
        }

        if let rhsFirstLine, isTableRow(rhsFirstLine) || isTableSeparator(rhsFirstLine) {
            if let leftLastNonEmptyLine, isTableRow(leftLastNonEmptyLine) || isTableSeparator(leftLastNonEmptyLine) {
                return leftText.hasSuffix("\n") ? "" : "\n"
            }
            return leftText.hasSuffix("\n\n") ? "" : leftText.hasSuffix("\n") ? "\n" : "\n\n"
        }

        if let leftLastNonEmptyLine, isHeading(leftLastNonEmptyLine), rhsFirstLine != nil {
            return leftText.hasSuffix("\n\n") ? "" : leftText.hasSuffix("\n") ? "\n" : "\n\n"
        }

        if let rhsFirstLine, startsBlock(rhsFirstLine) {
            return leftText.hasSuffix("\n\n") ? "" : leftText.hasSuffix("\n") ? "\n" : "\n\n"
        }

        guard let last = leftText.last, let first = rightText.first else { return "" }
        if last.isWhitespace || first.isWhitespace {
            return ""
        }
        // A bare, no-adjacent-whitespace seam sitting right at a length-capped
        // storage cut is far more likely to be a raw provider delta split
        // mid-word (subword tokenization routinely fragments a word like
        // "consideration" into "consid" + "eration" across two deltas) than
        // two genuinely separate, unspaced sentences. Glue it back with no
        // separator instead of guessing a space that was never in the stream.
        if leftWasCoalescingCut {
            return ""
        }
        return " "
    }

    private static func fenceLineCount(in text: String) -> Int {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isFenceLine)
            .count
    }

    private static func splitHeadingAndTableHeader(
        _ line: String,
        nextLine: String?
    ) -> (heading: String, tableHeader: String)? {
        guard let nextLine,
              isTableSeparator(nextLine.trimmingCharacters(in: .whitespaces)),
              let pipeIndex = line.firstIndex(of: "|") else {
            return nil
        }

        let heading = String(line[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
        let tableHeader = String(line[pipeIndex...]).trimmingCharacters(in: .whitespaces)
        guard isSpacedHeading(heading), isTableRow(tableHeader) else { return nil }
        return (heading, tableHeader)
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isHeading(trimmed) ||
            isFenceLine(trimmed) ||
            isDivider(trimmed) ||
            isBlockquote(trimmed) ||
            isListItem(trimmed)
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return false }
        let count = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count) else { return false }
        if count == trimmed.count { return false }
        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: count)
        return trimmed[contentStart].isWhitespace || trimmed[contentStart] != "#"
    }

    private static func isSpacedHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return false }
        let count = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), count < trimmed.count else { return false }
        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: count)
        return trimmed[contentStart].isWhitespace
    }

    private static func isTableRow(_ line: String) -> Bool {
        splitTableCells(line).count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy(isTableSeparatorCell)
    }

    private static func isTableSeparatorCell(_ cell: String) -> Bool {
        var value = cell.trimmingCharacters(in: .whitespaces)
        guard value.count >= 3 else { return false }
        if value.first == ":" {
            value.removeFirst()
        }
        if value.last == ":" {
            value.removeLast()
        }
        return value.count >= 3 && value.allSatisfy { $0 == "-" }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        guard row.contains("|") else { return [] }
        if row.hasPrefix("|") {
            row.removeFirst()
        }
        if row.hasSuffix("|") {
            row.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        var isInsideCodeSpan = false

        for character in row {
            if character == "`", !isEscaped {
                isInsideCodeSpan.toggle()
                current.append(character)
            } else if character == "|", !isEscaped, !isInsideCodeSpan {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }

            isEscaped = character == "\\" && !isEscaped
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func appendBlankIfNeeded(afterTable isInsideTable: inout Bool, output: inout [String]) {
        guard isInsideTable else { return }
        appendBlankIfNeeded(output: &output)
        isInsideTable = false
    }

    private static func appendBlankIfNeeded(output: inout [String]) {
        guard let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        output.append("")
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func lastNonEmptyLine(in text: String) -> String? {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    private static func nextNonEmptyLine(after index: Int, in lines: [String]) -> String? {
        guard index + 1 < lines.count else { return nil }
        for candidate in lines[(index + 1)...] {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func isFenceLine(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func isDivider(_ line: String) -> Bool {
        line == "---" || line == "***" || line == "___"
    }

    private static func isBlockquote(_ line: String) -> Bool {
        line.hasPrefix(">")
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }
        guard let dotIndex = line.firstIndex(of: "."),
              dotIndex != line.startIndex,
              line[line.startIndex..<dotIndex].allSatisfy(\.isNumber),
              line.index(after: dotIndex) < line.endIndex else {
            return false
        }
        return line[line.index(after: dotIndex)].isWhitespace
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func collapseExtraBlankLines(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\n\n")
    }
}

private extension Bool {
    mutating func toggle(ifOdd count: Int) {
        if !count.isMultiple(of: 2) {
            toggle()
        }
    }
}
