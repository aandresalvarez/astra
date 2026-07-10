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
/// is already literal) so each becomes its own paragraph/heading/list item.
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
            let nextLineHasContent = !(nextLine?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            if nextLineHasContent {
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
}
