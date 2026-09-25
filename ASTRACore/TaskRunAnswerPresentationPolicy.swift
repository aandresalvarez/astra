import Foundation

public struct TaskRunAnswerPresentation: Hashable, Sendable {
    public let answerText: String
    public let progressMessages: [String]
    public let rawText: String
}

public enum TaskRunAnswerPresentationPolicy {
    private static let longRawOutputThreshold = 1_200

    /// Conversation `TaskEvent` rows are coalesced up to this length before
    /// storage starts a new row purely because of the length cap, not a
    /// semantic gap in the text (see `AgentEventRecordingState`, which
    /// defaults its own cap to this value). `joinedResponsePayloads` uses it
    /// to recognize that seam and rejoin the row split without inserting a
    /// space that was never in the original stream.
    public static let conversationChunkCoalescingCap = 4_096

    public static func presentation(rawText: String) -> TaskRunAnswerPresentation {
        presentation(rawText: rawText, visible: normalizedVisibleText(rawText))
    }

    /// `joinedResponsePayloads` already returns normalized text. Feeding its
    /// result back through `presentation(rawText:)` runs the whole
    /// normalization pass -- sentence repair, blank-line collapse and the
    /// markdown reflow -- a second time over the same string, which doubles the
    /// per-run cost of every transcript rebuild while a task streams.
    /// Normalization is idempotent, so callers that already hold joined output
    /// use this entry point instead.
    public static func presentation(normalizedText: String) -> TaskRunAnswerPresentation {
        presentation(rawText: normalizedText, visible: normalizedText)
    }

    /// A run recorded with keyed messages: the answer's messages, each whole,
    /// joined with a paragraph break at every message boundary. No summary cut
    /// and no sentence repair: nothing was glued together, and the rule that
    /// chose these messages already decided what the answer is.
    public static func presentation(messages: [String]) -> TaskRunAnswerPresentation {
        let joined = messages
            .map { strippingProtocolMarkerLines(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let text = MarkdownRenderPreparation.prepareForDisplay(replace(regex: repeatedNewlineRegex, in: joined, template: "\n\n"))
        return TaskRunAnswerPresentation(answerText: text, progressMessages: [], rawText: joined)
    }

    private static func presentation(rawText: String, visible: String) -> TaskRunAnswerPresentation {
        let raw = rawText
        guard !visible.isEmpty else {
            return TaskRunAnswerPresentation(answerText: "", progressMessages: [], rawText: raw)
        }

        if let explicitAnswer = explicitAnswerSection(in: visible) {
            return TaskRunAnswerPresentation(
                answerText: explicitAnswer,
                progressMessages: [],
                rawText: raw
            )
        }

        let deduped = dedupeAdjacentSegments(in: visible)
        let progressSegments = segments(in: deduped).filter(isProgressSegment)
        if deduped.count > longRawOutputThreshold, progressSegments.count >= 3 {
            return TaskRunAnswerPresentation(
                answerText: compactLongProgressAnswer(from: deduped),
                progressMessages: Array(progressSegments.prefix(12)),
                rawText: raw
            )
        }

        return TaskRunAnswerPresentation(
            answerText: deduped,
            progressMessages: [],
            rawText: raw
        )
    }

    public static func joinedResponsePayloads(_ payloads: [String]) -> String {
        let visiblePayloads = payloads.map(strippingProtocolMarkerLines)
        let joined = MarkdownRenderPreparation.joinChunks(
            visiblePayloads,
            prepareForDisplay: false,
            coalescingCapHint: conversationChunkCoalescingCap
        )
        return normalizedVisibleText(joined)
    }

    public static func dedupedProgressTexts(_ texts: [String]) -> [String] {
        var output: [String] = []
        var previousKey: String?
        for text in texts {
            guard let progress = normalizedProgressText(text) else { continue }
            let normalized = progress.text
            let key = progress.comparisonKey
            guard !normalized.isEmpty, key != previousKey else { continue }
            output.append(normalized)
            previousKey = key
        }
        return output
    }

    public static func normalizedProgressText(_ text: String) -> (text: String, comparisonKey: String)? {
        let normalized = normalizedVisibleText(text)
        let key = comparisonKey(normalized)
        guard !normalized.isEmpty, !key.isEmpty else { return nil }
        return (normalized, key)
    }

    public static func summaryText(rawText: String, fallback: String = "", maxLength: Int) -> String {
        let presentation = presentation(rawText: rawText)
        let source = presentation.answerText.isEmpty ? normalizedVisibleText(fallback) : presentation.answerText
        guard !source.isEmpty else { return "" }
        guard source.count > maxLength else { return source }

        let prefix = String(source.prefix(maxLength))
        if let lastPeriod = prefix.lastIndex(of: ".") {
            return String(prefix[prefix.startIndex...lastPeriod])
        }
        if let lastNewline = prefix.lastIndex(of: "\n") {
            return String(prefix[prefix.startIndex..<lastNewline])
        }
        return prefix + "..."
    }

    /// Compiling an `NSRegularExpression` costs several times more than running
    /// an already compiled one, and `normalizedVisibleText` applies the two
    /// sentence-boundary patterns once per line of every transcript rebuild.
    /// Compile each pattern once for the process instead of once per line.
    private static let sentenceBoundaryRegex = try? NSRegularExpression(pattern: #"([.!?])([A-Z`#])"#)
    private static let boldSentenceBoundaryRegex = try? NSRegularExpression(pattern: #"([.!?])(\*\*[A-Za-z])"#)
    private static let repeatedNewlineRegex = try? NSRegularExpression(pattern: #"\n{3,}"#)
    private static let whitespaceRunRegex = try? NSRegularExpression(pattern: #"\s+"#)
    private static let sentenceSplitRegex = try? NSRegularExpression(pattern: #"([.!?])\s+"#)

    private static func normalizedVisibleText(_ text: String) -> String {
        var result = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = transformUnfencedLines(in: result) { line in
            var transformed = replace(regex: sentenceBoundaryRegex, in: line, template: "$1 $2")
            transformed = replace(regex: boldSentenceBoundaryRegex, in: transformed, template: "$1\n\n$2")
            return transformed
        }
        result = replace(regex: repeatedNewlineRegex, in: result, template: "\n\n")
        return MarkdownRenderPreparation.prepareForDisplay(result)
    }

    private static func transformUnfencedLines(
        in text: String,
        transform: (String) -> String
    ) -> String {
        var fenceTracker = MarkdownFenceTracker()
        return text.components(separatedBy: "\n").map { line in
            guard !fenceTracker.protects(line),
                  !line.hasPrefix("    "),
                  !line.hasPrefix("\t") else {
                return line
            }
            return transform(line)
        }.joined(separator: "\n")
    }

    private static func strippingProtocolMarkerLines(from text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
    }

    /// Runs recorded before messages were keyed: when the text has a summary
    /// section, show from its heading on. The heading must start its own line,
    /// the section must say something (40 or more visible characters after the
    /// heading), and it must not merely repeat lines already written above it,
    /// the way a re-sent copy of a message would. The last such section wins.
    private static func explicitAnswerSection(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for index in lines.indices.reversed() {
            guard let sameLine = summaryHeadingRemainder(lines[index]) else { continue }
            let body = ([sameLine] + lines[(index + 1)...]).joined(separator: "\n")
            guard body.filter({ !$0.isWhitespace && $0 != ":" && $0 != "*" }).count >= 40 else { continue }
            let earlier = Set(lines[..<index].map(comparisonKey).filter { !$0.isEmpty })
            let sectionLines = lines[(index + 1)...].map(comparisonKey).filter { !$0.isEmpty }
            if !sectionLines.isEmpty, sectionLines.allSatisfy(earlier.contains) { continue }
            let section = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return dedupeAdjacentSegments(in: section)
        }
        return nil
    }

    /// What follows a summary heading on its own line, or `nil` when the line
    /// is not one: a markdown heading titled Summary, Full Run Summary, Final
    /// Answer or Bottom line, or a line that opens with a Bottom line label.
    private static func summaryHeadingRemainder(_ line: String) -> String? {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("#") {
            let title = lower.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            for marker in ["full run summary", "summary", "final answer", "bottom line"] where title.hasPrefix(marker) {
                return String(title.dropFirst(marker.count))
            }
            return nil
        }
        for marker in ["**bottom line**", "bottom line"] where lower.hasPrefix(marker) {
            return String(lower.dropFirst(marker.count))
        }
        return nil
    }

    private static func compactLongProgressAnswer(from _: String) -> String {
        "This run produced a long progress log. Open Diagnostics for the raw output."
    }

    /// Dedupe must never change the text's structure class: paragraph text
    /// stays paragraphs, line-structured text keeps its line breaks (they
    /// carry markdown block boundaries such as `### `/`- ` at line starts),
    /// and only true single-line text falls back to sentence-level joining.
    private static func dedupeAdjacentSegments(in text: String) -> String {
        var fenceTracker = MarkdownFenceTracker()
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { fenceTracker.protects($0) }) else {
            return dedupeUnfencedSegments(in: text)
        }

        fenceTracker = MarkdownFenceTracker()
        var chunks: [(protected: Bool, lines: [String])] = []
        for line in lines {
            let isProtected = fenceTracker.protects(line)
            if chunks.last?.protected == isProtected {
                chunks[chunks.count - 1].lines.append(line)
            } else {
                chunks.append((isProtected, [line]))
            }
        }
        return chunks.map { chunk in
            let value = chunk.lines.joined(separator: "\n")
            return chunk.protected ? value : dedupeUnfencedSegments(in: value)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dedupeUnfencedSegments(in text: String) -> String {
        if text.contains("\n\n") {
            return dedupedSegments(text.components(separatedBy: "\n\n"), joinedBy: "\n\n")
        }
        if text.contains("\n") {
            return dedupedSegments(text.components(separatedBy: "\n"), joinedBy: "\n")
        }
        let repaired = replace(regex: sentenceSplitRegex, in: text, template: "$1\n")
        return dedupedSegments(repaired.components(separatedBy: "\n"), joinedBy: " ")
    }

    private static func dedupedSegments(_ rawSegments: [String], joinedBy separator: String) -> String {
        var output: [String] = []
        var previousKey: String?
        for segment in rawSegments {
            // Key on collapsed whitespace but emit the ORIGINAL segment:
            // trimming per line would strip significant indentation from
            // fenced code that reaches the line tier (no blank lines).
            let key = comparisonKey(segment)
            guard !key.isEmpty, key != previousKey else { continue }
            output.append(segment)
            previousKey = key
        }
        return output.joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func segments(in text: String) -> [String] {
        let paragraphSegments = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphSegments.count > 1 {
            return paragraphSegments
        }
        let repaired = replace(regex: sentenceSplitRegex, in: text, template: "$1\n")
        return repaired
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isProgressSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        return lower.hasPrefix("let me ") ||
            lower.contains("let me check") ||
            lower.contains("let me continue") ||
            lower.contains("let me wait") ||
            lower.contains("keep monitoring") ||
            lower.contains("keep polling") ||
            lower.contains("continue monitoring") ||
            lower.contains("continue polling") ||
            lower.contains("continuing to wait") ||
            lower.contains("build is running") ||
            lower.contains("build is progressing") ||
            lower.contains("new output") ||
            lower.contains("heartbeat") ||
            lower.contains("now at ~") ||
            lower.contains("still running") ||
            lower.contains("still building") ||
            lower.contains("progress is moving") ||
            lower.contains("good progress")
    }

    private static func comparisonKey(_ text: String) -> String {
        replace(regex: whitespaceRunRegex, in: text, template: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func replace(regex: NSRegularExpression?, in text: String, template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
