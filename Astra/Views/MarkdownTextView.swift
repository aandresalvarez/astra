import SwiftUI
import AppKit

private extension View {
    @ViewBuilder
    func markdownTextSelection(_ isSelectable: Bool) -> some View {
        if isSelectable {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}

/// Renders text as formatted markdown with support for headers, bold, italic,
/// code blocks, lists, tables, dividers, blockquotes, and system notices.
struct MarkdownTextView: View, Equatable {
    let text: String
    let maxContentWidth: CGFloat?
    let onSuggestedNextStep: ((String) -> Void)?
    let isSelectable: Bool
    @State private var blocks: [MarkdownBlock] = []
    @State private var skippedSuggestionIDs: Set<UUID> = []

    /// `.equatable()` skips unchanged bubbles; closure *presence* affects rendering (Cluster 4).
    static func == (lhs: MarkdownTextView, rhs: MarkdownTextView) -> Bool {
        lhs.text == rhs.text
            && lhs.maxContentWidth == rhs.maxContentWidth
            && lhs.isSelectable == rhs.isSelectable
            && (lhs.onSuggestedNextStep == nil) == (rhs.onSuggestedNextStep == nil)
    }

    init(
        text: String,
        maxContentWidth: CGFloat? = Stanford.chatParagraphMaxWidth,
        onSuggestedNextStep: ((String) -> Void)? = nil,
        isSelectable: Bool = true
    ) {
        self.text = text
        self.maxContentWidth = maxContentWidth
        self.onSuggestedNextStep = onSuggestedNextStep
        self.isSelectable = isSelectable
        _blocks = State(initialValue: Self.cachedParse(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                markdownBlockView(
                    block,
                    suggestedNextActions: suggestedNextActions(for: block, at: index)
                )
                    .frame(maxWidth: maxWidth(for: block), alignment: .leading)
                    .padding(.top, topSpacing(for: block, previous: index > 0 ? blocks[index - 1] : nil))
            }
        }
        .markdownTextSelection(isSelectable)
        .tint(Stanford.link)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text) { _, newText in
            blocks = Self.cachedParse(newText)
            skippedSuggestionIDs.removeAll(keepingCapacity: true)
        }
    }

    @ViewBuilder
    private func markdownBlockView(_ block: MarkdownBlock, suggestedNextActions: [SuggestedNextAction] = []) -> some View {
        switch block.kind {
        case .codeBlock(let lang):
            codeBlockView(lang: lang, code: block.content)

        case .table:
            tableView(block.content)

        case .divider:
            Divider()
                .padding(.vertical, 6)

        case .heading(let level):
            Text(Self.markdownAttributed(block.content))
                .font(level == 1 ? Stanford.heading(20) : level == 2 ? Stanford.heading(18) : Stanford.heading(16))
                .foregroundStyle(Stanford.readingText)
                .padding(.bottom, 2)

        case .listItem(let depth, let marker):
            VStack(alignment: .leading, spacing: 5) {
                // NOTE: `.top` (not `.firstTextBaseline`) is deliberate. The body
                // Text is selectable (`.textSelection` is enabled on the enclosing
                // MarkdownTextView), so SwiftUI hosts it in a `SelectionOverlay`
                // NSView. A baseline-aligned HStack must query that hosted view's
                // baseline via `FallbackAlignmentProvider`, which invalidates the
                // overlay's layout metrics on every pass and live-locks the main
                // thread in an infinite layout loop the moment a markdown list
                // renders. Aligning to `.top` removes the baseline query.
                HStack(alignment: .top, spacing: 8) {
                    Text(marker)
                        .font(Stanford.chatBody(depth == 0 ? 15 : 13))
                        .foregroundStyle(Stanford.coolGrey.opacity(0.72))
                        .frame(width: 24, alignment: .trailing)
                        .padding(.leading, CGFloat(depth) * 18)
                    Text(Self.markdownAttributed(block.content))
                        .font(Stanford.chatBody())
                        .foregroundStyle(Stanford.readingText)
                        .markdownTextSelection(isSelectable)
                        .lineSpacing(Stanford.chatCompactLineSpacing)
                }

                if let suggestedNextStep = suggestedNextActions.first,
                   let onSuggestedNextStep,
                   !skippedSuggestionIDs.contains(block.id) {
                    SuggestedNextStepControls(
                        onPursue: { onSuggestedNextStep(suggestedNextStep.composerText) },
                        onSkip: { skippedSuggestionIDs.insert(block.id) }
                    )
                    .padding(.leading, 32 + CGFloat(depth) * 18)
                }
            }
            .padding(.vertical, 1)

        case .blockquote:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Stanford.sandstone.opacity(0.5))
                    .frame(width: 3)
                Text(Self.markdownAttributed(block.content, whitespaceMode: .preserving))
                    .font(Stanford.documentExcerpt())
                    .italic()
                    .foregroundStyle(Stanford.readingText.opacity(0.78))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .lineSpacing(Stanford.chatBodyLineSpacing)
            }
            .background(Stanford.fog.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .notice:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(Stanford.ui(14))
                    .foregroundStyle(Stanford.lagunita)
                    .padding(.top, 1)
                Text(Self.markdownAttributed(block.content))
                    .font(Stanford.chatBody(15))
                    .foregroundStyle(Stanford.readingText)
                    .lineSpacing(Stanford.chatCompactLineSpacing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Stanford.lagunita.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .label:
            Text(Self.markdownAttributed(block.content))
                .font(Stanford.chatSection())
                .foregroundStyle(Stanford.readingText)

        case .blank:
            Color.clear.frame(height: 2)

        case .text:
            VStack(alignment: .leading, spacing: 7) {
                Text(Self.markdownAttributed(block.content))
                    .font(Stanford.chatBody())
                    .foregroundStyle(Stanford.readingText)
                    .markdownTextSelection(isSelectable)
                    .lineSpacing(Stanford.chatBodyLineSpacing)

                if !suggestedNextActions.isEmpty,
                   let onSuggestedNextStep,
                   !skippedSuggestionIDs.contains(block.id) {
                    SuggestedNextActionChips(
                        actions: suggestedNextActions,
                        onPursue: { action in onSuggestedNextStep(action.composerText) },
                        onSkip: { skippedSuggestionIDs.insert(block.id) }
                    )
                }
            }
        }
    }

    private func topSpacing(for block: MarkdownBlock, previous: MarkdownBlock?) -> CGFloat {
        guard let previous else { return 0 }
        if previous.kind == .blank { return 0 }

        switch block.kind {
        case .blank:
            return 6
        case .heading:
            return previous.kind == .divider ? 8 : 14
        case .listItem:
            if case .listItem = previous.kind { return 6 }
            return 8
        case .codeBlock, .table, .blockquote, .notice:
            return 10
        case .divider:
            return 12
        case .label:
            return 10
        case .text:
            switch previous.kind {
            case .heading, .label:
                return 6
            case .text:
                return 9
            default:
                return 8
            }
        }
    }

    private func maxWidth(for block: MarkdownBlock) -> CGFloat? {
        guard let maxContentWidth else { return nil }
        switch block.kind {
        case .table:
            return maxContentWidth
        default:
            return maxContentWidth
        }
    }

    private func suggestedNextActions(for block: MarkdownBlock, at index: Int) -> [SuggestedNextAction] {
        guard onSuggestedNextStep != nil else { return [] }
        return Self.suggestedNextActions(for: block, at: index, in: blocks)
    }

    static func suggestedNextActions(in blocks: [MarkdownBlock]) -> [SuggestedNextAction] {
        blocks.enumerated().flatMap { index, block in
            suggestedNextActions(for: block, at: index, in: blocks)
        }
    }

    static func suggestedNextActions(for block: MarkdownBlock, at index: Int, in blocks: [MarkdownBlock]) -> [SuggestedNextAction] {
        switch block.kind {
        case .listItem(let depth, _):
            guard depth == 0,
                  isInsideSuggestedNextStepsSection(index: index, blocks: blocks),
                  let title = normalizedSuggestedAction(block.content) else {
                return []
            }
            return [SuggestedNextAction(title: title)]

        case .text:
            return inlineSuggestedNextActions(from: block.content)

        default:
            return []
        }
    }

    private static func isInsideSuggestedNextStepsSection(index: Int, blocks: [MarkdownBlock]) -> Bool {
        guard index > 0 else { return false }
        for priorIndex in stride(from: index - 1, through: 0, by: -1) {
            let prior = blocks[priorIndex]
            if case .heading = prior.kind {
                let heading = prior.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return heading == "next steps" || heading == "suggested next steps"
            }
            if case .divider = prior.kind { return false }
        }
        return false
    }

    private static func inlineSuggestedNextActions(from content: String) -> [SuggestedNextAction] {
        let plain = plainMarkdownText(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remainder = inlineSuggestionRemainder(from: plain) else { return [] }

        var seen = Set<String>()
        var actions: [SuggestedNextAction] = []
        for candidate in splitInlineSuggestionRemainder(remainder) {
            guard let title = normalizedSuggestedAction(candidate) else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            actions.append(SuggestedNextAction(title: title))
            if actions.count == 4 { break }
        }
        return actions
    }

    private static func inlineSuggestionRemainder(from text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = normalized.lowercased()
        for prefix in ["next suggestion:", "next suggestions:"] where lowercase.hasPrefix(prefix) {
            let start = normalized.index(normalized.startIndex, offsetBy: prefix.count)
            let remainder = normalized[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    private static func splitInlineSuggestionRemainder(_ text: String) -> [String] {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ";", with: ",")

        while let last = normalized.last, [".", "!", "?"].contains(last) {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commaParts = normalized
            .split(separator: ",")
            .map { String($0) }

        if commaParts.count > 1 {
            return commaParts
        }

        return [normalized]
    }

    private static func normalizedSuggestedAction(_ text: String) -> String? {
        var value = plainMarkdownText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        for conjunction in ["and ", "or "] {
            if value.lowercased().hasPrefix(conjunction) {
                value = String(value.dropFirst(conjunction.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".;:,")))

        guard value.count >= 3,
              value.count <= 140,
              value.rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        return value
    }

    private final class MarkdownBlockCacheEntry {
        let blocks: [MarkdownBlock]

        init(blocks: [MarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private static let parseCache: NSCache<NSString, MarkdownBlockCacheEntry> = {
        let cache = NSCache<NSString, MarkdownBlockCacheEntry>()
        cache.countLimit = 500
        return cache
    }()

    private static func cachedParse(_ text: String) -> [MarkdownBlock] {
        let prepared = MarkdownRenderPreparation.prepareForDisplay(text)
        let key = NSString(string: prepared)
        if let cached = parseCache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = parsePrepared(prepared)
        parseCache.setObject(MarkdownBlockCacheEntry(blocks: blocks), forKey: key)
        return blocks
    }

    // MARK: - Code Block

    private func codeBlockView(lang: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !lang.isEmpty {
                    Text(lang)
                        .font(Stanford.chatRaw(11).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                        .textCase(.uppercase)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(Stanford.ui(11))
                        Text("Copy")
                            .font(Stanford.ui(11))
                    }
                    .foregroundStyle(Stanford.coolGrey)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Stanford.chatRaw())
                    .foregroundStyle(Stanford.readingText)
                    .markdownTextSelection(isSelectable)
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.fog.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Table Rendering

    private func tableView(_ raw: String) -> some View {
        let table = Self.parseTable(raw)
        let columnWidths = Self.tableColumnWidths(table.rows, columnCount: table.columnCount)
        let numericColumns = Self.numericTableColumns(table.rows, columnCount: table.columnCount)
        let tableWidth = Self.tableRenderedWidth(columnWidths, columnCount: table.columnCount)
        let showsOverflowCue = tableWidth > min(maxContentWidth ?? Stanford.chatParagraphMaxWidth, Stanford.chatParagraphMaxWidth)

        return ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIdx, cells in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<table.columnCount, id: \.self) { colIdx in
                                let cell = colIdx < cells.count ? cells[colIdx] : ""
                                let alignment = numericColumns.contains(colIdx) ? MarkdownTableAlignment.trailing : table.alignment(for: colIdx)

                                tableCellView(cell, rowIndex: rowIdx, alignment: alignment)
                                    .frame(width: columnWidths[colIdx], alignment: alignment.frameAlignment)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)

                                if colIdx < table.columnCount - 1 {
                                    Divider()
                                        .opacity(0.25)
                                }
                            }
                        }
                        .background(rowIdx == 0 ? Stanford.fog.opacity(0.5) : (rowIdx % 2 == 0 ? Stanford.fog.opacity(0.2) : Color.clear))

                        if rowIdx == 0 {
                            Divider()
                                .opacity(0.35)
                        } else if table.rows.count >= 5 && rowIdx < table.rows.count - 1 {
                            Divider()
                                .opacity(0.16)
                        }
                    }
                }
                .frame(width: tableWidth, alignment: .leading)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.visible)

            if showsOverflowCue {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor).opacity(0),
                        Color(nsColor: .windowBackgroundColor).opacity(0.84)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 26)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder
    private func tableCellView(
        _ cell: String,
        rowIndex: Int,
        alignment: MarkdownTableAlignment
    ) -> some View {
        if rowIndex > 0, let statusColor = Self.tableStatusStyle(for: cell) {
            Text(cell)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(statusColor)
                .markdownTextSelection(isSelectable)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.10))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else if rowIndex > 0, Self.isNumericTableCell(cell) {
            Text(cell)
                .font(Stanford.chatRaw(13))
                .foregroundStyle(Stanford.readingText)
                .markdownTextSelection(isSelectable)
                .multilineTextAlignment(alignment.textAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else {
            Text(Self.markdownAttributed(cell))
                .font(rowIndex == 0 ? Stanford.chatSection(13) : Stanford.chatBody(14))
                .foregroundStyle(Stanford.readingText)
                .markdownTextSelection(isSelectable)
                .multilineTextAlignment(alignment.textAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        }
    }

    private enum MarkdownTableAlignment {
        case leading
        case center
        case trailing

        var textAlignment: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var frameAlignment: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    private struct MarkdownTable {
        let rows: [[String]]
        let alignments: [MarkdownTableAlignment]
        let columnCount: Int

        func alignment(for index: Int) -> MarkdownTableAlignment {
            index < alignments.count ? alignments[index] : .leading
        }
    }

    private static func parseTable(_ raw: String) -> MarkdownTable {
        let lines = raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else {
            return MarkdownTable(rows: [], alignments: [], columnCount: 0)
        }

        var rows: [[String]] = []
        var alignments: [MarkdownTableAlignment] = []

        for line in lines {
            let cells = splitTableCells(line)
            if let separatorAlignments = tableSeparatorAlignments(cells) {
                alignments = separatorAlignments
            } else {
                rows.append(cells)
            }
        }

        let columnCount = max(
            rows.map(\.count).max() ?? 0,
            alignments.count
        )

        return MarkdownTable(
            rows: rows,
            alignments: alignments,
            columnCount: columnCount
        )
    }

    private static func tableColumnWidths(_ rows: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }

        return (0..<columnCount).map { column in
            let maxLength = rows.map { row in
                column < row.count ? row[column].count : 0
            }.max() ?? 0

            return max(88, min(320, CGFloat(maxLength) * 7.5 + 32))
        }
    }

    private static func tableRenderedWidth(_ widths: [CGFloat], columnCount: Int) -> CGFloat {
        let dividerWidth = max(0, columnCount - 1)
        let horizontalPadding = CGFloat(columnCount) * 24
        return widths.reduce(0, +) + horizontalPadding + CGFloat(dividerWidth)
    }

    private static func numericTableColumns(_ rows: [[String]], columnCount: Int) -> Set<Int> {
        guard rows.count > 1 else { return [] }
        var result = Set<Int>()
        for column in 0..<columnCount {
            let bodyCells = rows.dropFirst().compactMap { row -> String? in
                guard column < row.count else { return nil }
                let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            guard !bodyCells.isEmpty,
                  bodyCells.allSatisfy(isNumericTableCell) else { continue }
            result.insert(column)
        }
        return result
    }

    private static func isNumericTableCell(_ cell: String) -> Bool {
        let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.,:%$€£¥+-() hHkKmMbBtT")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func tableStatusStyle(for cell: String) -> Color? {
        let normalized = cell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("in progress") || normalized.contains("open") {
            return Stanford.poppy
        }
        if normalized.contains("waiting") || normalized.contains("blocked") {
            return Stanford.sky
        }
        if normalized.contains("done") || normalized.contains("complete") || normalized.contains("resolved") {
            return Stanford.completed
        }
        if normalized.contains("failed") || normalized.contains("error") || normalized.contains("budget") {
            return Stanford.failed
        }
        if normalized.contains("cancelled") || normalized.contains("canceled") {
            return Stanford.cancelled
        }
        if ["critical", "highest", "urgent"].contains(normalized) {
            return Stanford.failed
        }
        if normalized == "high" {
            return Stanford.poppy
        }
        if normalized == "medium" || normalized == "normal" {
            return Stanford.lagunita
        }
        if normalized == "low" || normalized == "unassigned" {
            return Stanford.coolGrey
        }
        return nil
    }

    // MARK: - Parsing

    enum BlockKind: Equatable {
        case text
        case codeBlock(language: String)
        case table
        case divider
        case heading(level: Int)
        case listItem(depth: Int, marker: String)
        case blockquote
        case notice
        case label
        case blank
    }

    struct MarkdownBlock: Identifiable {
        let id = UUID()
        let kind: BlockKind
        let content: String
    }

    struct SuggestedNextAction: Identifiable, Equatable {
        let id: String
        let title: String
        let composerText: String

        init(title: String) {
            self.title = title
            self.composerText = title
            self.id = title.lowercased()
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let prepared = MarkdownRenderPreparation.prepareForDisplay(text)
        return parsePrepared(prepared)
    }

    private static func parsePrepared(_ prepared: String) -> [MarkdownBlock] {
        if let astBlocks = MarkdownASTBlockParser.parse(prepared), !astBlocks.isEmpty {
            return astBlocks
        }

        return parseLegacy(prepared)
    }

    private static func parseLegacy(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        func flushText() {
            let joined = normalizedParagraph(textBuffer)
            if !joined.isEmpty {
                blocks.append(MarkdownBlock(kind: .text, content: joined))
            }
            textBuffer = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block (```)
            if trimmed.hasPrefix("```") {
                flushText()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(MarkdownBlock(kind: .codeBlock(language: lang), content: codeLines.joined(separator: "\n")))
                continue
            }

            // Horizontal rule / divider (---, ***, ___)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                blocks.append(MarkdownBlock(kind: .divider, content: ""))
                i += 1
                continue
            }

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushText()
                // Only add blank if the previous block wasn't already a blank/divider
                if let last = blocks.last, last.kind != .blank && last.kind != .divider {
                    blocks.append(MarkdownBlock(kind: .blank, content: ""))
                }
                i += 1
                continue
            }

            // Headings (# through ######), including permissive "#Title" output.
            if let heading = Self.headingMatch(trimmed) {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level), content: heading.content))
                i += 1
                continue
            }

            // Setext headings:
            // Title
            // =====
            if textBuffer.isEmpty,
               i + 1 < lines.count,
               let level = Self.setextHeadingLevel(lines[i + 1]),
               !trimmed.isEmpty,
               !trimmed.contains("|") {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: level), content: trimmed))
                i += 2
                continue
            }

            // List items (- item, * item, + item, or numbered 1. item)
            if let listMatch = Self.listItemMatch(trimmed) {
                flushText()
                let depth = (line.count - line.drop(while: { $0 == " " }).count) / 2
                let marker = listMatch.marker == "\u{2022}" && depth > 0 ? "\u{25E6}" : listMatch.marker
                blocks.append(MarkdownBlock(
                    kind: .listItem(depth: min(depth, 3), marker: marker),
                    content: listMatch.content
                ))
                i += 1
                continue
            }

            // Blockquotes (> text), including quoted blank lines as paragraph breaks.
            if let firstQuoteLine = Self.blockquoteLineContent(trimmed) {
                flushText()
                var quoteLines: [String] = [firstQuoteLine]
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if let quoteLine = Self.blockquoteLineContent(nextTrimmed) {
                        quoteLines.append(quoteLine)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(kind: .blockquote, content: normalizedBlockquote(quoteLines)))
                continue
            }

            // System notices: [Reminder: ...], [Note: ...], [Warning: ...]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") &&
               (trimmed.contains("Reminder:") || trimmed.contains("Note:") || trimmed.contains("Warning:")) {
                flushText()
                let inner = String(trimmed.dropFirst().dropLast())
                blocks.append(MarkdownBlock(kind: .notice, content: inner))
                i += 1
                continue
            }

            // GitHub-style table detection. Supports optional leading/trailing pipes:
            // A | B
            // --- | ---
            if let table = Self.tableBlock(startingAt: i, in: lines) {
                flushText()
                blocks.append(MarkdownBlock(kind: .table, content: table.lines.joined(separator: "\n")))
                i = table.nextIndex
                continue
            }

            // Label lines: "Something:" at end of a short line (< 60 chars, ends with colon)
            if trimmed.hasSuffix(":") && trimmed.count < 60 && !trimmed.contains("//") {
                flushText()
                blocks.append(MarkdownBlock(kind: .label, content: trimmed))
                i += 1
                continue
            }

            textBuffer.append(line)
            i += 1
        }

        flushText()
        return blocks
    }

    static func normalizedStreamingText(_ text: String) -> String {
        let lines = MarkdownRenderPreparation.prepareForDisplay(text).components(separatedBy: "\n")
        var normalizedLines: [String] = []
        var paragraph: [String] = []
        var isInsideCodeBlock = false

        func flushParagraph() {
            let normalized = normalizedParagraph(paragraph)
            if !normalized.isEmpty {
                normalizedLines.append(normalized)
            }
            paragraph = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                isInsideCodeBlock.toggle()
                normalizedLines.append(line)
                continue
            }
            if isInsideCodeBlock {
                normalizedLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                if normalizedLines.last?.isEmpty != true {
                    normalizedLines.append("")
                }
                continue
            }
            if headingMatch(trimmed) != nil ||
                listItemMatch(trimmed) != nil ||
                blockquoteLineContent(trimmed) != nil ||
                tableHeaderCells(line) != nil {
                flushParagraph()
                normalizedLines.append(line)
                continue
            }
            paragraph.append(line)
        }

        flushParagraph()
        return normalizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedParagraph(_ lines: [String]) -> String {
        var segments: [String] = []
        var current = ""

        for rawLine in lines {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            let hasMarkdownHardBreak = rawLine.hasSuffix("  ") || trimmedLine.hasSuffix("\\")
            let segment = trimmedLine.hasSuffix("\\")
                ? String(trimmedLine.dropLast()).trimmingCharacters(in: .whitespaces)
                : trimmedLine
            guard !segment.isEmpty else { continue }

            if current.isEmpty {
                current = segment
            } else {
                current += " " + segment
            }

            if hasMarkdownHardBreak {
                segments.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            segments.append(current)
        }

        return repairMissingSentenceSpaces(segments.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBlockquote(_ lines: [String]) -> String {
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let shouldPreserveLineBreaks = lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ||
            nonEmptyLines.filter { $0.count <= 72 }.count > nonEmptyLines.count / 2

        if shouldPreserveLineBreaks {
            return lines
                .map { repairMissingSentenceSpaces($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalizedParagraph(lines)
    }

    private static func repairMissingSentenceSpaces(_ text: String) -> String {
        let pattern = #"([a-z0-9][.!?])([A-Z][a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1 $2"
        )
    }

    private static func headingMatch(_ line: String) -> (level: Int, content: String)? {
        guard line.first == "#" else { return nil }

        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }

        let contentStart = line.index(line.startIndex, offsetBy: hashes)
        var content = String(line[contentStart...])
        if content.first?.isWhitespace == true {
            content = content.trimmingCharacters(in: .whitespaces)
        }

        content = stripClosingHeadingHashes(content)
        guard !content.isEmpty else { return nil }

        return (hashes, content)
    }

    private static func stripClosingHeadingHashes(_ content: String) -> String {
        var trimmed = content.trimmingCharacters(in: .whitespaces)

        guard let lastNonHash = trimmed.lastIndex(where: { $0 != "#" }) else {
            return trimmed
        }

        let hashStart = trimmed.index(after: lastNonHash)
        guard hashStart < trimmed.endIndex,
              trimmed[lastNonHash].isWhitespace else {
            return trimmed
        }

        trimmed.removeSubrange(hashStart..<trimmed.endIndex)
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    private static func setextHeadingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func tableBlock(startingAt index: Int, in lines: [String]) -> (lines: [String], nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        guard tableHeaderCells(lines[index]) != nil else { return nil }

        let separatorCells = splitTableCells(lines[index + 1])
        guard tableSeparatorAlignments(separatorCells) != nil else { return nil }

        var tableLines = [lines[index], lines[index + 1]]
        var nextIndex = index + 2

        while nextIndex < lines.count {
            let candidate = lines[nextIndex]
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  tableHeaderCells(candidate) != nil,
                  tableSeparatorAlignments(splitTableCells(candidate)) == nil else {
                break
            }

            tableLines.append(candidate)
            nextIndex += 1
        }

        return (tableLines, nextIndex)
    }

    private static func tableHeaderCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        let cells = splitTableCells(line)
        guard cells.count >= 2 else { return nil }
        return cells
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
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

            if character == "\\" && !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func tableSeparatorAlignments(_ cells: [String]) -> [MarkdownTableAlignment]? {
        guard cells.count >= 2 else { return nil }

        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            guard let alignment = tableSeparatorAlignment(cell) else { return nil }
            alignments.append(alignment)
        }
        return alignments
    }

    private static func tableSeparatorAlignment(_ cell: String) -> MarkdownTableAlignment? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }

        let startsWithColon = trimmed.hasPrefix(":")
        let endsWithColon = trimmed.hasSuffix(":")
        var dashes = trimmed
        if startsWithColon {
            dashes.removeFirst()
        }
        if endsWithColon {
            dashes.removeLast()
        }

        guard dashes.count >= 3,
              dashes.allSatisfy({ $0 == "-" }) else {
            return nil
        }

        if startsWithColon && endsWithColon { return .center }
        if endsWithColon { return .trailing }
        return .leading
    }

    /// Match list item prefixes: "- ", "* ", "+ ", "1. ", "2. " etc.
    private static func listItemMatch(_ line: String) -> (marker: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return ("\u{2022}", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("* ") && !trimmed.hasPrefix("**") { return ("\u{2022}", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("+ ") { return ("\u{2022}", String(trimmed.dropFirst(2))) }
        // Numbered: "1. ", "2. ", etc.
        if let dotIdx = trimmed.firstIndex(of: "."),
           dotIdx != trimmed.startIndex,
           trimmed[trimmed.startIndex..<dotIdx].allSatisfy(\.isNumber),
           trimmed.index(after: dotIdx) < trimmed.endIndex,
           trimmed[trimmed.index(after: dotIdx)] == " " {
            let marker = String(trimmed[trimmed.startIndex...dotIdx])
            return (marker, String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...]))
        }
        return nil
    }

    private static func blockquoteLineContent(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        var content = String(line.dropFirst())
        if content.first?.isWhitespace == true {
            content.removeFirst()
        }
        return content
    }

    static func markdownAttributed(
        _ text: String,
        whitespaceMode: MarkdownLinkifier.WhitespaceMode = .normalized
    ) -> AttributedString {
        MarkdownLinkifier.markdownAttributed(text, whitespaceMode: whitespaceMode)
    }

    static func plainMarkdownText(_ text: String) -> String {
        String(markdownAttributed(text).characters)
    }

    static func monospacedTableText(_ raw: String) -> String {
        let table = parseTable(raw)
        guard table.columnCount > 0, !table.rows.isEmpty else { return raw }

        let widths = (0..<table.columnCount).map { column in
            max(
                3,
                table.rows.map { row in
                    column < row.count ? row[column].count : 0
                }.max() ?? 0
            )
        }

        func padded(_ value: String, column: Int) -> String {
            let width = widths[column]
            let padding = max(0, width - value.count)

            switch table.alignment(for: column) {
            case .leading:
                return value + String(repeating: " ", count: padding)
            case .center:
                let leading = padding / 2
                let trailing = padding - leading
                return String(repeating: " ", count: leading) + value + String(repeating: " ", count: trailing)
            case .trailing:
                return String(repeating: " ", count: padding) + value
            }
        }

        func rowText(_ cells: [String]) -> String {
            (0..<table.columnCount)
                .map { column in
                    padded(column < cells.count ? cells[column] : "", column: column)
                }
                .joined(separator: "  ")
        }

        let separator = widths.enumerated()
            .map { column, width in
                padded(String(repeating: "-", count: width), column: column)
            }
            .joined(separator: "  ")

        var renderedRows: [String] = []
        for (index, row) in table.rows.enumerated() {
            renderedRows.append(rowText(row))
            if index == 0 {
                renderedRows.append(separator)
            }
        }

        return renderedRows.joined(separator: "\n")
    }
}

private struct SuggestedNextStepControls: View {
    let onPursue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPursue) {
                Label("Pursue", systemImage: "arrow.right.circle")
                    .font(Stanford.caption(11).weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Stanford.lagunita.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
            )
            .help("Move this suggestion into the composer")

            Button(action: onSkip) {
                Text("Skip")
                    .font(Stanford.caption(11).weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Hide this suggestion")
        }
        .textSelection(.disabled)
    }
}

private struct SuggestedNextActionChips: View {
    let actions: [MarkdownTextView.SuggestedNextAction]
    let onPursue: (MarkdownTextView.SuggestedNextAction) -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        actionButton(action)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(actions) { action in
                        actionButton(action)
                            .frame(maxWidth: 340, alignment: .leading)
                    }
                }
            }

            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(Stanford.caption(10).weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Stanford.coolGrey.opacity(0.78))
            .help("Hide these suggestions")
            .accessibilityLabel("Hide suggested actions")
        }
        .textSelection(.disabled)
    }

    private func actionButton(_ action: MarkdownTextView.SuggestedNextAction) -> some View {
        Button {
            onPursue(action)
        } label: {
            Label {
                Text(action.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "arrow.right.circle")
            }
            .font(Stanford.caption(11).weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Stanford.lagunita)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Stanford.lagunita.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
        )
        .help("Move \"\(action.title)\" into the composer")
        .accessibilityLabel("Pursue suggestion: \(action.title)")
    }
}
