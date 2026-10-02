import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

/// Summarizes a bounded sample for presentation. Original TaskEvent rows remain
/// the sole durable evidence; paging and prompt budgets own working-set size.
enum AgentEventCompactor {
    static let threshold = 200
    static let keepCount = 50
    private static let summaryPrefix = "History summary (original details retained)."
    private static let semanticLineLimit = 12

    private enum FilePathPattern {
        static let regex = try? NSRegularExpression(pattern: #"(?:~|/)[A-Za-z0-9._~+@%=\-/:]+"#)
    }

    @MainActor
    static func compactEvents(for task: AgentTask, modelContext: ModelContext) {
        let start = DispatchTime.now().uptimeNanoseconds
        RuntimeSettlementProgress.pruneSettledCaptures(task: task, modelContext: modelContext)
        let taskID = task.id
        let summaryType = TaskEventTypes.Activity.compacted.rawValue
        let captured = TaskEventTypes.System.runtimeResultCaptured.rawValue
        let prepared = TaskEventTypes.System.runtimeOutcomePrepared.rawValue
        let predicate = #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.type != summaryType && $0.type != captured && $0.type != prepared
        }
        do {
            let count = try modelContext.fetchCount(FetchDescriptor<TaskEvent>(predicate: predicate))
            guard count > threshold else { return }
            // Never fault the whole relationship just to prepare a summary.
            var descriptor = FetchDescriptor<TaskEvent>(predicate: predicate,
                sortBy: [SortDescriptor(\TaskEvent.timestamp, order: .reverse), SortDescriptor(\TaskEvent.id, order: .reverse)])
            descriptor.fetchLimit = keepCount + threshold
            let sample = Array(try modelContext.fetch(descriptor).dropFirst(keepCount).reversed())
            var counts: [String: Int] = [:]
            for event in sample { counts[event.type, default: 0] += 1 }
            let breakdown = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            let payload = "\(summaryPrefix)\n\(count - keepCount) older events; sample of \(sample.count): \(breakdown)"
                + "\nCompacted detail index:\n" + semanticSummaryLines(from: sample).joined(separator: "\n")
                + "\nEvidence remains in task history. Latest sampled event: \(sample.last?.id.uuidString ?? "none")."
            let summaries = FetchDescriptor<TaskEvent>(
                predicate: #Predicate<TaskEvent> { $0.task?.id == taskID && $0.type == summaryType },
                sortBy: [SortDescriptor(\TaskEvent.timestamp, order: .reverse)])
            // Legacy deletion summaries contain the only surviving description
            // of their lost details. Never overwrite those.
            let summary = try modelContext.fetch(summaries).first { $0.payload.hasPrefix(summaryPrefix) }
            guard summary?.payload != payload else { return }
            if let summary {
                summary.payload = RunSecretRedactionScope.redact(payload, taskID: task.id)
                summary.timestamp = sample.last?.timestamp ?? Date()
            } else {
                let summary = TaskEvent(task: task, type: summaryType, payload: payload)
                summary.timestamp = sample.last?.timestamp ?? Date()
                modelContext.insert(summary)
            }
            TaskThreadHistoryInvalidation.invalidate(taskID: task.id)
            PerformanceTelemetry.logIfNeeded("event_compaction", start: start,
                thresholdMilliseconds: PerformanceTelemetry.backgroundThresholdMilliseconds,
                fields: ["task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
                         "event_count": PerformanceTelemetryFields.count(count),
                         "sample_count": PerformanceTelemetryFields.count(sample.count),
                         "deleted_count": "0"])
        } catch {
            // Auxiliary summary failure must neither discard evidence nor fail
            // settlement. The next explicit finalization can retry it.
            AppLogger.error("History summary failed: \(error.localizedDescription)", category: "Worker")
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
        guard !text.isEmpty, let regex = FilePathPattern.regex else {
            return []
        }
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
