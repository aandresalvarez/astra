import Foundation

/// Rendering helpers for workspace instructions. The instructions box is a
/// plain `TextEditor`, not a CommonMark authoring tool: users press Return
/// once per directive and expect that line break to stay visually distinct.
/// Left to swift-markdown alone, consecutive non-blank lines are one
/// soft-wrapped paragraph — and `MarkdownASTBlockParser.normalizedParagraph`
/// flattens *any* line break inside a paragraph (hard or soft) back to a
/// single space, since it exists to undo incidental line-wrapping in chat
/// prose. A `\` hard-break marker is therefore a no-op here: it only affects
/// inline layout within one AST block, and this parser collapses that right
/// back out. The only way to keep a line visually distinct is to make it its
/// *own* block. `preparedForRendering` does that by inserting a genuine blank
/// line between adjacent authored lines (skipping fenced code, where content
/// is already literal) so each becomes its own paragraph/heading/list item —
/// except where CommonMark itself requires lines to stay adjacent (a setext
/// heading underline, the rows of a GFM table), where splitting them would
/// corrupt the construct instead of merely losing its formatting.
/// The original `workspace.instructions` string is never mutated — this only
/// transforms the copy handed to `MarkdownTextView`.
enum WorkspaceInstructionMarkdown {
    static func preparedForRendering(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var result: [String] = []
        result.reserveCapacity(lines.count * 2)
        var isInsideFence = false

        for (index, line) in lines.enumerated() {
            result.append(line)

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideFence.toggle()
                continue
            }

            guard !isInsideFence, !trimmed.isEmpty else { continue }

            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            let nextTrimmed = nextLine?.trimmingCharacters(in: .whitespaces) ?? ""
            let nextLineHasContent = !nextTrimmed.isEmpty
            // A setext heading underline (`===`/`---`) only parses when it
            // stays on the line directly below its title — splitting the pair
            // doesn't just lose the heading, a `---` underline on its own
            // becomes an unrelated thematic break. A table's rows (header,
            // separator, and every data row) all need to stay adjacent to each
            // other too, or the table breaks at the first gap; checking both
            // sides of the gap keeps a whole contiguous run of rows together
            // without needing to special-case which row is the separator.
            let nextLineRequiresAdjacency = isSetextHeadingUnderline(nextTrimmed)
                || (isPipeTableRow(trimmed) && isPipeTableRow(nextTrimmed))
            if nextLineHasContent && !nextLineRequiresAdjacency {
                result.append("")
            }
        }

        return result.joined(separator: "\n")
    }

    /// A short, human-readable stand-in for "N guidance items" — counts real
    /// Markdown sections (headings) when present, otherwise falls back to a
    /// word count so trivial one-line prompts don't get a hollow "0 sections".
    static func summary(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        let wordsLabel = "\(roundedCount(words)) word\(words == 1 ? "" : "s")"

        let sections = headingCount(in: trimmed)
        guard sections > 0 else { return wordsLabel }
        return "\(sections) section\(sections == 1 ? "" : "s") · \(wordsLabel)"
    }

    // MARK: - Private

    private static func headingCount(in text: String) -> Int {
        let blocks = MarkdownASTBlockParser.parse(preparedForRendering(text)) ?? []
        return blocks.reduce(into: 0) { count, block in
            if case .heading = block.kind { count += 1 }
        }
    }

    private static func roundedCount(_ count: Int) -> String {
        guard count >= 100 else { return "\(count)" }
        let rounded = Int((Double(count) / 10).rounded()) * 10
        return "~\(rounded)"
    }

    /// A setext heading underline: one or more of the same character (`=` for
    /// H1, `-` for H2), nothing else. Note this has no 3-character minimum —
    /// unlike a thematic break (`---`), a bare `-` or `=` is already valid.
    private static func isSetextHeadingUnderline(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.isEmpty else { return false }
        let characters = Set(trimmedLine)
        return characters == ["-"] || characters == ["="]
    }

    /// A pipe-delimited table row — header, separator (`| --- | --- |`), or
    /// data row alike. Deliberately lenient (just "has at least one non-empty
    /// `|`-delimited cell") rather than validating separator-row syntax
    /// specifically: every row in a table needs the same adjacency
    /// protection, not just the header/separator pair, and a false positive
    /// here only costs an unrelated pair of pipe-containing lines their split
    /// — a soft-wrap merge, not a corrupted render.
    private static func isPipeTableRow(_ trimmedLine: String) -> Bool {
        guard trimmedLine.contains("|") else { return false }
        var row = trimmedLine
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
