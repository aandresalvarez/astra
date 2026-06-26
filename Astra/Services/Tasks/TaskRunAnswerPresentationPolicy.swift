import Foundation

struct TaskRunAnswerPresentation: Hashable, Sendable {
    let answerText: String
    let progressMessages: [String]
    let rawText: String
}

enum TaskRunAnswerPresentationPolicy {
    private static let longRawOutputThreshold = 1_200

    static func presentation(rawText: String) -> TaskRunAnswerPresentation {
        let raw = rawText
        let visible = normalizedVisibleText(raw)
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

    static func joinedResponsePayloads(_ payloads: [String]) -> String {
        MarkdownRenderPreparation.joinChunks(payloads.map { normalizedVisibleText($0) })
    }

    static func dedupedProgressTexts(_ texts: [String]) -> [String] {
        var output: [String] = []
        var previousKey: String?
        for text in texts {
            let normalized = normalizedVisibleText(text)
            let key = comparisonKey(normalized)
            guard !normalized.isEmpty, key != previousKey else { continue }
            output.append(normalized)
            previousKey = key
        }
        return output
    }

    static func summaryText(rawText: String, fallback: String = "", maxLength: Int) -> String {
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

    private static func normalizedVisibleText(_ text: String) -> String {
        var result = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = replace(pattern: #"([.!?])([A-Z`#])"#, in: result, template: "$1 $2")
        result = replace(pattern: #"([.!?])(\*\*[A-Za-z])"#, in: result, template: "$1\n\n$2")
        result = replace(pattern: #"\n{3,}"#, in: result, template: "\n\n")
        return MarkdownRenderPreparation.prepareForDisplay(result)
    }

    private static func explicitAnswerSection(in text: String) -> String? {
        let markers = [
            "## Full Run Summary",
            "## Summary",
            "### Summary",
            "## Final Answer",
            "### Final Answer",
            "**Bottom line**",
            "Bottom line"
        ]
        let lower = text.lowercased()
        for marker in markers {
            guard let range = lower.range(of: marker.lowercased(), options: .backwards) else { continue }
            let suffix = String(text[range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.count >= 20 {
                return dedupeAdjacentSegments(in: suffix)
            }
        }
        return nil
    }

    private static func compactLongProgressAnswer(from _: String) -> String {
        "This run produced a long progress log. Open Diagnostics for the raw output."
    }

    private static func dedupeAdjacentSegments(in text: String) -> String {
        let separator = text.contains("\n\n") ? "\n\n" : " "
        var output: [String] = []
        var previousKey: String?
        for segment in segments(in: text) {
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
        let repaired = replace(pattern: #"([.!?])\s+"#, in: text, template: "$1\n")
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
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func replace(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
