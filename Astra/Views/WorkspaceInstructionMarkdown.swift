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
/// line between adjacent authored lines (skipping fenced or indented code,
/// where content is already literal) so each becomes its own
/// paragraph/heading/list item — except where CommonMark itself requires
/// lines to stay adjacent (a setext heading underline, the rows of a GFM
/// table), where splitting them would corrupt the construct instead of
/// merely losing its formatting.
/// The original `workspace.instructions` string is never mutated — this only
/// transforms the copy handed to `MarkdownTextView`.
enum WorkspaceInstructionMarkdown {
    static func preparedForRendering(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        let protectedTableRows = tableRowIndices(in: lines)

        var result: [String] = []
        result.reserveCapacity(lines.count * 2)
        var openFence: FenceDelimiter?

        for (index, line) in lines.enumerated() {
            result.append(line)

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = fenceDelimiter(in: line) {
                if let open = openFence {
                    if delimiter.closes(open) {
                        openFence = nil
                        continue
                    }
                    // Fence-shaped but doesn't match the open fence's character
                    // or length, or has non-whitespace text trailing the
                    // marker (CommonMark only lets a *closing* fence be
                    // followed by spaces — an opening fence's info string,
                    // like the "swift" in ` ```swift `, doesn't count as a
                    // close) — treated as literal content inside the fence,
                    // so fall through to the still-open guard below instead
                    // of toggling here.
                } else {
                    openFence = delimiter
                    continue
                }
            }

            guard openFence == nil, !trimmed.isEmpty else { continue }

            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            let nextTrimmed = nextLine?.trimmingCharacters(in: .whitespaces) ?? ""
            let nextLineHasContent = !nextTrimmed.isEmpty
            // A setext heading underline (`===`/`---`) only parses when it
            // stays on the line directly below its title — splitting the pair
            // doesn't just lose the heading, a `---` underline on its own
            // becomes an unrelated thematic break. A confirmed GFM table's
            // rows all need to stay adjacent too, or the table breaks at the
            // first gap. An indented code block (4+ leading spaces, no fence)
            // is literal content just like a fenced block, so a run of them
            // needs the same protection fenced blocks already get.
            let nextLineRequiresAdjacency = isSetextHeadingUnderline(nextTrimmed)
                || (protectedTableRows.contains(index) && protectedTableRows.contains(index + 1))
                || (isIndentedCodeLine(line) && isIndentedCodeLine(nextLine ?? ""))
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

    /// A fenced-code delimiter's character, run length, and whether anything
    /// but whitespace trails it. CommonMark closes a fence only on a
    /// delimiter of the *same* character that is *at least as long* as the
    /// opener *and* is followed by nothing but spaces — tracking just
    /// "is this fence-shaped" isn't enough, or a nested ` ``` ` shown inside a
    /// ```` ```` -fenced example (or a stray `~~~` inside a backtick fence, or
    /// a ` ```swift ` info-string line demonstrating fence syntax) would
    /// prematurely close it.
    private struct FenceDelimiter {
        let character: Character
        let length: Int
        let hasTrailingContent: Bool

        func closes(_ opener: FenceDelimiter) -> Bool {
            character == opener.character && length >= opener.length && !hasTrailingContent
        }
    }

    /// A fenced-code delimiter candidate: a run of 3+ backticks or tildes
    /// preceded by at most 3 spaces. CommonMark treats 4+ leading spaces as
    /// an indented code block instead — trimming *all* leading whitespace
    /// before checking would wrongly recognize a delimiter the real parser
    /// ignores. `hasTrailingContent` only matters when this candidate is
    /// tested as a *closer* (via `closes`) — an opener is allowed an info
    /// string (` ```swift `), so it's ignored on the open path.
    private static func fenceDelimiter(in line: String) -> FenceDelimiter? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let content = line.dropFirst(leadingSpaces)
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let run = content.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let trailing = content.dropFirst(run.count)
        return FenceDelimiter(
            character: first,
            length: run.count,
            hasTrailingContent: !trailing.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    /// A setext heading underline: one or more of the same character (`=` for
    /// H1, `-` for H2), nothing else. Note this has no 3-character minimum —
    /// unlike a thematic break (`---`), a bare `-` or `=` is already valid.
    private static func isSetextHeadingUnderline(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.isEmpty else { return false }
        let characters = Set(trimmedLine)
        return characters == ["-"] || characters == ["="]
    }

    /// A line CommonMark treats as an indented code block: 4+ leading spaces
    /// and some non-whitespace content. Checked against the *untrimmed* line
    /// — the indentation itself is the signal, so a caller must not pass in
    /// an already-trimmed string.
    private static func isIndentedCodeLine(_ line: String) -> Bool {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces >= 4 else { return false }
        return !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Line indices that belong to a *confirmed* GFM table: a header row
    /// immediately followed by a genuine separator row (`| --- | --- |`,
    /// dash-only cells), plus every consecutive pipe-shaped row that follows.
    /// Requiring an actual separator row — not just "this line contains a
    /// `|`" — is what keeps two unrelated prose lines that each happen to
    /// mention a pipe (a shell pipeline example, say: "`ls | grep foo`" next
    /// to "`cat file | wc -l`") from being wrongly recognized as a table and
    /// merged back into one paragraph.
    private static func tableRowIndices(in lines: [String]) -> Set<Int> {
        var protectedIndices: Set<Int> = []

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard isTableSeparatorRow(trimmed) else { continue }
            guard index > 0 else { continue }
            let headerTrimmed = lines[index - 1].trimmingCharacters(in: .whitespaces)
            guard isPipeTableRow(headerTrimmed) else { continue }

            protectedIndices.insert(index - 1)
            protectedIndices.insert(index)

            var dataRowIndex = index + 1
            while dataRowIndex < lines.count {
                let candidate = lines[dataRowIndex].trimmingCharacters(in: .whitespaces)
                guard isPipeTableRow(candidate) else { break }
                protectedIndices.insert(dataRowIndex)
                dataRowIndex += 1
            }
        }

        return protectedIndices
    }

    /// A pipe-delimited row shape — header, separator, or data row alike.
    /// Deliberately lenient (just "has at least one non-empty `|`-delimited
    /// cell"): once `tableRowIndices` has confirmed a real table is present
    /// via its separator row, every row in it (including data rows that
    /// don't share the separator's strict dash-only syntax) needs the same
    /// adjacency protection. Never used on its own to *start* a table — see
    /// `isTableSeparatorRow` for that.
    private static func isPipeTableRow(_ trimmedLine: String) -> Bool {
        guard trimmedLine.contains("|") else { return false }
        var row = trimmedLine
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A genuine GFM table separator row: every `|`-delimited cell is
    /// nothing but dashes (with optional leading/trailing `:` for alignment).
    /// This is the strict check — the one signal that reliably proves a
    /// table is actually present, as opposed to two lines that merely
    /// contain a `|` character.
    private static func isTableSeparatorRow(_ trimmedLine: String) -> Bool {
        guard trimmedLine.contains("|"), trimmedLine.contains("-") else { return false }
        var row = trimmedLine
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        guard !row.isEmpty else { return false }

        let cells = row.components(separatedBy: "|")
        guard !cells.isEmpty else { return false }

        return cells.allSatisfy { cell in
            var inner = cell.trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty else { return false }
            if inner.hasPrefix(":") { inner.removeFirst() }
            if inner.hasSuffix(":") { inner.removeLast() }
            return !inner.isEmpty && inner.allSatisfy { $0 == "-" }
        }
    }
}
