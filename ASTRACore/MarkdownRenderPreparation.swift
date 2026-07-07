import Foundation

public enum MarkdownRenderPreparation {
    public static func prepareForDisplay(_ text: String) -> String {
        let normalized = normalizedLineEndings(text)
        return repairBlockBoundaries(in: normalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func joinChunks(_ chunks: [String], prepareForDisplay: Bool = true) -> String {
        var joined = ""
        var currentLastNonEmptyLine: String?
        var hasUnclosedFence = false

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
                    rightText: chunk
                ) + chunk
            }
            currentLastNonEmptyLine = lastNonEmptyLine(in: chunk) ?? currentLastNonEmptyLine
            hasUnclosedFence.toggle(ifOdd: fenceLineCount(in: chunk))
        }

        return prepareForDisplay ? self.prepareForDisplay(joined) : joined
    }

    private static func repairBlockBoundaries(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var isInsideFence = false
        var isInsideTable = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isFenceLine(trimmed) {
                appendBlankIfNeeded(afterTable: &isInsideTable, output: &output)
                output.append(line)
                isInsideFence.toggle()
                index += 1
                continue
            }

            if isInsideFence {
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
