import Foundation
import Markdown

enum MarkdownASTBlockParser {
    typealias MarkdownBlock = MarkdownTextView.MarkdownBlock
    typealias BlockKind = MarkdownTextView.BlockKind

    static func parse(_ text: String) -> [MarkdownBlock]? {
        let normalized = normalizedLineEndings(text)
        let document = Document(parsing: normalized)
        let blocks = blocks(from: document.children, depth: 0)
        return blocks.isEmpty ? nil : blocks
    }

    private static func blocks(from children: MarkupChildren, depth: Int) -> [MarkdownBlock] {
        children.flatMap { blocks(from: $0, depth: depth) }
    }

    private static func blocks(from markup: Markup, depth: Int) -> [MarkdownBlock] {
        if let heading = markup as? Heading {
            return [
                MarkdownBlock(
                    kind: .heading(level: min(max(heading.level, 1), 6)),
                    content: normalizedInlineText(from: heading)
                )
            ]
        }

        if let paragraph = markup as? Paragraph {
            return paragraphBlock(from: paragraph)
        }

        if let codeBlock = markup as? CodeBlock {
            return [
                MarkdownBlock(
                    kind: .codeBlock(language: codeBlock.language ?? ""),
                    content: trimmedTrailingNewlines(codeBlock.code)
                )
            ]
        }

        if markup is ThematicBreak {
            return [MarkdownBlock(kind: .divider, content: "")]
        }

        if let blockQuote = markup as? BlockQuote {
            let content = blockQuote.children
                .map { blockquoteContent(from: $0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            return content.isEmpty ? [] : [
                MarkdownBlock(kind: .blockquote, content: content)
            ]
        }

        if let orderedList = markup as? OrderedList {
            return orderedListBlocks(from: orderedList, depth: depth)
        }

        if let unorderedList = markup as? UnorderedList {
            return unorderedListBlocks(from: unorderedList, depth: depth)
        }

        if let table = markup as? Table, let tableMarkdown = tableMarkdown(from: table) {
            return [MarkdownBlock(kind: .table, content: tableMarkdown)]
        }

        let fallback = normalizedParagraph([markup.format()])
        return fallback.isEmpty ? [] : [MarkdownBlock(kind: .text, content: fallback)]
    }

    private static func paragraphBlock(from paragraph: Paragraph) -> [MarkdownBlock] {
        let content = normalizedInlineText(from: paragraph)
        guard !content.isEmpty else { return [] }

        if let heading = headingMatch(content) {
            return [
                MarkdownBlock(
                    kind: .heading(level: heading.level),
                    content: heading.content
                )
            ]
        }

        if isSystemNotice(content) {
            return [
                MarkdownBlock(
                    kind: .notice,
                    content: String(content.dropFirst().dropLast())
                )
            ]
        }

        if content.hasSuffix(":") && content.count < 60 && !content.contains("//") {
            return [MarkdownBlock(kind: .label, content: content)]
        }

        return [MarkdownBlock(kind: .text, content: content)]
    }

    private static func orderedListBlocks(from list: OrderedList, depth: Int) -> [MarkdownBlock] {
        var index = Int(list.startIndex)
        var result: [MarkdownBlock] = []

        for child in list.children {
            guard let item = child as? ListItem else { continue }
            result.append(contentsOf: listItemBlocks(
                from: item,
                depth: depth,
                marker: "\(index)."
            ))
            index += 1
        }

        return result
    }

    private static func unorderedListBlocks(from list: UnorderedList, depth: Int) -> [MarkdownBlock] {
        let marker = depth > 0 ? "\u{25E6}" : "\u{2022}"

        return list.children.flatMap { child -> [MarkdownBlock] in
            guard let item = child as? ListItem else { return [] }
            return listItemBlocks(from: item, depth: depth, marker: marker)
        }
    }

    private static func listItemBlocks(
        from item: ListItem,
        depth: Int,
        marker: String
    ) -> [MarkdownBlock] {
        var contentParts: [String] = []
        var nestedBlocks: [MarkdownBlock] = []

        for child in item.children {
            if let orderedList = child as? OrderedList {
                nestedBlocks.append(contentsOf: orderedListBlocks(from: orderedList, depth: depth + 1))
                continue
            }

            if let unorderedList = child as? UnorderedList {
                nestedBlocks.append(contentsOf: unorderedListBlocks(from: unorderedList, depth: depth + 1))
                continue
            }

            if let paragraph = child as? Paragraph {
                contentParts.append(normalizedInlineText(from: paragraph))
                continue
            }

            let childBlocks = blocks(from: child, depth: depth)
            for block in childBlocks {
                switch block.kind {
                case .text, .label:
                    contentParts.append(block.content)
                default:
                    nestedBlocks.append(block)
                }
            }
        }

        var content = contentParts
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if let checkbox = item.checkbox {
            switch checkbox {
            case .checked:
                content = "[x] \(content)"
            case .unchecked:
                content = "[ ] \(content)"
            }
        }

        var result: [MarkdownBlock] = []
        if !content.isEmpty {
            result.append(MarkdownBlock(
                kind: .listItem(depth: min(depth, 3), marker: marker),
                content: content
            ))
        }
        result.append(contentsOf: nestedBlocks)
        return result
    }

    private static func blockquoteContent(from markup: Markup) -> String {
        if let paragraph = markup as? Paragraph {
            return normalizedInlineText(from: paragraph)
        }

        if let heading = markup as? Heading {
            return normalizedInlineText(from: heading)
        }

        if let codeBlock = markup as? CodeBlock {
            return trimmedTrailingNewlines(codeBlock.code)
        }

        if let orderedList = markup as? OrderedList {
            return orderedListBlocks(from: orderedList, depth: 0)
                .map { "\($0.content)" }
                .joined(separator: "\n")
        }

        if let unorderedList = markup as? UnorderedList {
            return unorderedListBlocks(from: unorderedList, depth: 0)
                .map { "\($0.content)" }
                .joined(separator: "\n")
        }

        return normalizedParagraph([markup.format()])
    }

    private static func tableMarkdown(from table: Table) -> String? {
        let headerCells = Array(table.head.cells.map { tableCellText($0) })
        guard !headerCells.isEmpty else { return nil }

        let alignments = table.columnAlignments
        let separators = (0..<headerCells.count).map { index in
            guard index < alignments.count else { return "---" }

            switch alignments[index] {
            case .center:
                return ":---:"
            case .right:
                return "---:"
            case .left, nil:
                return "---"
            @unknown default:
                return "---"
            }
        }

        let bodyRows = table.body.rows.map { row in
            Array(row.cells.map { tableCellText($0) }).joined(separator: " | ")
        }

        return ([headerCells.joined(separator: " | "), separators.joined(separator: " | ")] + bodyRows)
            .joined(separator: "\n")
    }

    private static func tableCellText(_ cell: Table.Cell) -> String {
        normalizedInlineText(from: cell)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func normalizedInlineText(from markup: Markup) -> String {
        normalizedParagraph(inlineMarkdown(from: markup).components(separatedBy: "\n"))
    }

    private static func inlineMarkdown(from markup: Markup) -> String {
        if let tableCell = markup as? Table.Cell {
            return inlineMarkdown(from: tableCell.children)
        }

        if let text = markup as? Markdown.Text {
            return text.string
        }

        if let inlineCode = markup as? InlineCode {
            return inlineCodeMarkdown(inlineCode.code)
        }

        if markup is SoftBreak {
            return "\n"
        }

        if markup is LineBreak {
            return "\n"
        }

        if let strong = markup as? Strong {
            return "**\(inlineMarkdown(from: strong.children))**"
        }

        if let emphasis = markup as? Emphasis {
            return "*\(inlineMarkdown(from: emphasis.children))*"
        }

        if let strikethrough = markup as? Strikethrough {
            return "~~\(inlineMarkdown(from: strikethrough.children))~~"
        }

        if let link = markup as? Link {
            let label = inlineMarkdown(from: link.children)
            guard let destination = link.destination, !destination.isEmpty else {
                return label
            }
            return "[\(label)](\(destination))"
        }

        if let image = markup as? Markdown.Image {
            let alt = inlineMarkdown(from: image.children)
            guard let source = image.source, !source.isEmpty else {
                return alt
            }
            return "![\(alt)](\(source))"
        }

        if let html = markup as? InlineHTML {
            return html.rawHTML
        }

        if let symbolLink = markup as? SymbolLink {
            return "``\(symbolLink.destination ?? "")``"
        }

        if markup.childCount > 0 {
            return inlineMarkdown(from: markup.children)
        }

        return stripBlockWrapping(markup.format())
    }

    private static func inlineMarkdown(from children: MarkupChildren) -> String {
        children.map { inlineMarkdown(from: $0) }.joined()
    }

    private static func inlineCodeMarkdown(_ code: String) -> String {
        let fence = code.contains("`") ? "``" : "`"
        return "\(fence)\(code)\(fence)"
    }

    private static func stripBlockWrapping(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedParagraph(_ lines: [String]) -> String {
        var result = ""

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if result.isEmpty {
                result = trimmed
            } else if result.hasSuffix("-") {
                result.removeLast()
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }

        return repairMissingSentenceSpaces(result)
    }

    private static func repairMissingSentenceSpaces(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 3 else { return text }

        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)

        for index in scalars.indices {
            let scalar = scalars[index]
            result.append(scalar)

            guard index + 1 < scalars.count else { continue }
            let next = scalars[index + 1]

            if scalar == "." || scalar == "!" || scalar == "?" {
                let nextIsUppercase = CharacterSet.uppercaseLetters.contains(next)
                if nextIsUppercase {
                    result.append(" ")
                }
            }
        }

        return String(result)
    }

    private static func isSystemNotice(_ content: String) -> Bool {
        content.hasPrefix("[") &&
            content.hasSuffix("]") &&
            (
                content.contains("Reminder:") ||
                content.contains("Note:") ||
                content.contains("Warning:")
            )
    }

    private static func headingMatch(_ line: String) -> (level: Int, content: String)? {
        guard line.first == "#" else { return nil }

        var count = 0
        for character in line {
            if character == "#" {
                count += 1
            } else {
                break
            }
        }

        guard (1...6).contains(count) else { return nil }
        let dropIndex = line.index(line.startIndex, offsetBy: count)
        let remainder = String(line[dropIndex...]).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        return (level: count, content: remainder)
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func trimmedTrailingNewlines(_ text: String) -> String {
        var value = text
        while value.last == "\n" || value.last == "\r" {
            value.removeLast()
        }
        return value
    }
}
