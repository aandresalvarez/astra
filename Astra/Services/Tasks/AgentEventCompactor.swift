import Foundation
import SwiftData

enum AgentEventCompactor {
    static let threshold = 200
    static let keepCount = 50

    private enum FilePathPattern {
        static let regex = try! NSRegularExpression(pattern: #"(?:~|/)[A-Za-z0-9._~+@%=\-/:]+"#)
    }
    private static let semanticLineLimit = 12

    @MainActor
    static func compactEvents(for task: AgentTask, modelContext: ModelContext) {
        let events = task.events.sorted { $0.timestamp < $1.timestamp }
        guard events.count > threshold else { return }

        let cutoff = events.count - keepCount
        let toCompact = events
            .prefix(cutoff)
            .filter { !shouldPreserveDuringCompaction($0) }
        guard !toCompact.isEmpty else { return }

        var typeCounts: [String: Int] = [:]
        for event in toCompact {
            typeCounts[event.type, default: 0] += 1
        }

        let summary = typeCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        let semanticLines = semanticSummaryLines(from: toCompact)
        var payload = "Compacted \(toCompact.count) earlier events. Breakdown: \(summary)"
        if !semanticLines.isEmpty {
            payload += "\nCompacted detail index:\n" + semanticLines.joined(separator: "\n")
        }

        let summaryEvent = TaskEvent(
            task: task,
            type: "activity.compacted",
            payload: payload
        )
        if let firstKept = events.dropFirst(cutoff).first {
            summaryEvent.timestamp = firstKept.timestamp.addingTimeInterval(-1)
        }
        modelContext.insert(summaryEvent)

        for event in toCompact {
            modelContext.delete(event)
        }

        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "event": "activity_compacted",
            "compacted_count": String(toCompact.count),
            "kept_count": String(keepCount)
        ])
    }

    private static func shouldPreserveDuringCompaction(_ event: TaskEvent) -> Bool {
        if event.type.hasPrefix("astra.") {
            return true
        }

        switch event.type {
        case "user.message",
             "schedule.result",
             "system.info",
             "recap.result",
             "budget.warning",
             "budget.exceeded",
             "permission.denied",
             "permission.approval.requested",
             "local_agent.watchdog",
             "local_agent.metrics",
             "error",
             "task.completed",
             "task.cancelled",
             "task.interrupted":
            return true
        default:
            return false
        }
    }

    private static func semanticSummaryLines(from events: [TaskEvent]) -> [String] {
        var commands: [String] = []
        var paths: [String] = []
        var outcomes: [String] = []
        var decisions: [String] = []
        var unresolved: [String] = []
        var preferences: [String] = []

        for event in events {
            if let command = compactToolCommand(from: event) {
                commands.append(command)
            }
            paths.append(contentsOf: filePaths(in: event.payload))
            if let outcome = compactOutcome(from: event) {
                outcomes.append(outcome)
            }
            if let decision = compactDecision(from: event) {
                decisions.append(decision)
            }
            if let blocker = compactUnresolvedIssue(from: event) {
                unresolved.append(blocker)
            }
            if let preference = compactUserPreference(from: event) {
                preferences.append(preference)
            }
        }

        var lines: [String] = []
        if !decisions.isEmpty {
            lines.append("- Decisions: \(dedupeKeepingOrder(decisions, limit: 5).joined(separator: " | "))")
        }
        if !unresolved.isEmpty {
            lines.append("- Unresolved bugs/blockers: \(dedupeKeepingOrder(unresolved, limit: 5).joined(separator: " | "))")
        }
        if !preferences.isEmpty {
            lines.append("- User preferences: \(dedupeKeepingOrder(preferences, limit: 5).joined(separator: " | "))")
        }
        if !commands.isEmpty {
            lines.append("- Commands/tools: \(dedupeKeepingOrder(commands, limit: 5).joined(separator: "; "))")
        }
        if !paths.isEmpty {
            lines.append("- Files/paths: \(dedupeKeepingOrder(paths, limit: 6).joined(separator: "; "))")
        }
        if !outcomes.isEmpty {
            lines.append("- Validation/blockers: \(dedupeKeepingOrder(outcomes, limit: 5).joined(separator: " | "))")
        }
        return Array(lines
            .map { boundedInline($0, maxCharacters: 700) }
            .prefix(semanticLineLimit))
    }

    private static func compactToolCommand(from event: TaskEvent) -> String? {
        let payload = boundedInline(event.payload, maxCharacters: 500)
        guard !payload.isEmpty else { return nil }
        if event.type == "tool.use" {
            if payload.hasPrefix("Using tool:") {
                let value = String(payload.dropFirst("Using tool:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            return payload
        }
        let lower = payload.lowercased()
        if lower.contains("swift test") || lower.contains("running validation tests") {
            return payload
        }
        return nil
    }

    private static func compactDecision(from event: TaskEvent) -> String? {
        let payload = boundedInline(event.payload, maxCharacters: 500)
        guard !payload.isEmpty else { return nil }
        let lower = payload.lowercased()
        let hasDecisionSignal = lower.contains("decision:") ||
            lower.contains("decided") ||
            lower.contains("approved plan") ||
            lower.contains("accepted plan") ||
            lower.contains("we will") ||
            lower.contains("we should") ||
            lower.contains("use ") && lower.contains(" as ")
        guard hasDecisionSignal else { return nil }
        return "\(event.type): \(payload)"
    }

    private static func compactUnresolvedIssue(from event: TaskEvent) -> String? {
        let payload = boundedInline(event.payload, maxCharacters: 500)
        guard !payload.isEmpty else { return nil }
        let lower = payload.lowercased()
        let hasUnresolvedSignal = lower.contains("unresolved") ||
            lower.contains("blocker") ||
            lower.contains("blocked") ||
            lower.contains("still failing") ||
            lower.contains("not fixed") ||
            lower.contains("regression") ||
            lower.contains("bug:")
        guard hasUnresolvedSignal else { return nil }
        return "\(event.type): \(payload)"
    }

    private static func compactUserPreference(from event: TaskEvent) -> String? {
        let payload = boundedInline(event.payload, maxCharacters: 500)
        guard !payload.isEmpty else { return nil }
        let lower = payload.lowercased()
        let hasPreferenceSignal = lower.contains("user prefers") ||
            lower.contains("user preference") ||
            lower.contains("preference:") ||
            lower.contains("always ") ||
            lower.contains("never ")
        guard hasPreferenceSignal else { return nil }
        return "\(event.type): \(payload)"
    }

    private static func compactOutcome(from event: TaskEvent) -> String? {
        let payload = boundedInline(event.payload, maxCharacters: 420)
        guard !payload.isEmpty else { return nil }
        let lower = payload.lowercased()
        let outcomeTypes: Set<String> = ["tool.result", "task.completed"]
        let hasOutcomeKeyword = [
            "test",
            "validation",
            "failed",
            "passed",
            "error",
            "permission",
            "budget",
            "blocked"
        ].contains { lower.contains($0) }
        guard outcomeTypes.contains(event.type) || hasOutcomeKeyword else { return nil }
        return "\(event.type): \(payload)"
    }

    private static func filePaths(in text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        let regex = FilePathPattern.regex
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let trimmed = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;)]}\"'`"))
            guard trimmed.count > 1, !trimmed.hasPrefix("//") else { return nil }
            return trimmed
        }
    }

    private static func dedupeKeepingOrder(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(trimmed)
            if output.count >= limit { break }
        }
        return output
    }

    private static func boundedInline(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "..."
    }
}
