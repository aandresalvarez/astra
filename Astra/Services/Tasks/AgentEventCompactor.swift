import Foundation
import SwiftData
import ASTRAModels

enum AgentEventCompactor {
    static let threshold = 200
    static let keepCount = 50
    private static let maxPreservedFinalResponseChunks = 24

    private enum FilePathPattern {
        /// Failable so a bad pattern degrades to "no paths in the compaction
        /// summary" instead of crashing at first use; the positive match is
        /// covered by `CompactionTests`, so a pattern typo fails CI.
        static let regex: NSRegularExpression? = {
            do {
                return try NSRegularExpression(pattern: #"(?:~|/)[A-Za-z0-9._~+@%=\-/:]+"#)
            } catch {
                AppLogger.error("File-path pattern failed to compile; compaction summaries omit paths: \(error)", category: "Worker")
                return nil
            }
        }()
    }
    private static let semanticLineLimit = 12

    /// Event-type namespaces whose state is reconstructed from the event log
    /// (`TaskPlanService.reconstruct`, the Context Capsule's validation/handoff/
    /// corrective summaries). Deleting these during compaction silently corrupts
    /// the derived state that feeds the prompt — e.g. an approved plan reverting
    /// to draft, or a passed contract reading back as not_verified.
    private static let reconstructedEventTypePrefixes = [
        "plan.",
        "validation.",
        "verifier.",
        "handoff.",
        "corrective.",
        "objective."
    ]

    /// Validation assertion event types. Grouped by `(planID, assertionID)` when
    /// deciding what to preserve, mirroring how the Context Capsule reads the latest
    /// event per assertion *within a plan* in `latestAssertionEventsByID(task:planID:)`.
    /// Scoping by planID prevents two plans that reuse an assertion id (e.g. "a1")
    /// from colliding and dropping the active plan's event.
    private static let validationAssertionEventTypes: Set<String> = [
        TaskValidationEventTypes.assertionDefined,
        TaskValidationEventTypes.assertionStarted,
        TaskValidationEventTypes.assertionPassed,
        TaskValidationEventTypes.assertionFailed,
        TaskValidationEventTypes.assertionSkipped,
        TaskValidationEventTypes.assertionReviewed
    ]

    /// Validation contract event types. Grouped by `(planID, type)` so each plan's
    /// latest contract outcome survives, mirroring how the capsule filters contract
    /// events by `payload.planID` in `validationContractState`.
    private static let validationContractEventTypes: Set<String> = [
        TaskValidationEventTypes.contractCreated,
        TaskValidationEventTypes.contractUpdated,
        TaskValidationEventTypes.contractPassed,
        TaskValidationEventTypes.contractFailed,
        TaskValidationEventTypes.contractOverridden
    ]

    @MainActor
    static func compactEvents(for task: AgentTask, modelContext: ModelContext) {
        let start = DispatchTime.now().uptimeNanoseconds
        let events = task.events.sorted { $0.timestamp < $1.timestamp }
        guard events.count > threshold else {
            logCompactionIfNeeded(
                start: start,
                taskID: task.id,
                eventCount: events.count,
                compactedCount: 0,
                keptCount: events.count,
                reconstructionCriticalCount: 0,
                summaryEventInserted: false
            )
            return
        }

        let cutoff = events.count - keepCount
        let compactionCandidates = events
            .prefix(cutoff)
            .filter { !shouldPreserveDuringCompaction($0) }
        // Keep the most recent reconstructed-lifecycle event per grouping key beyond
        // the recency window so plan/contract state still rebuilds after compaction
        // (see latestReconstructedEventIDs for the per-key rules). Bounded by the
        // number of distinct keys, so high-volume plan.step.* streams still compact.
        let reconstructionCriticalIDs = latestReconstructedEventIDs(in: compactionCandidates)
        let outputPresentationAnchorIDs = latestOutputPresentationAnchorIDs(in: compactionCandidates)
        let preservedIDs = reconstructionCriticalIDs.union(outputPresentationAnchorIDs)
        let toCompact = compactionCandidates.filter { !preservedIDs.contains($0.id) }
        guard !toCompact.isEmpty else {
            logCompactionIfNeeded(
                start: start,
                taskID: task.id,
                eventCount: events.count,
                compactedCount: 0,
                keptCount: events.count,
                reconstructionCriticalCount: reconstructionCriticalIDs.count,
                summaryEventInserted: false
            )
            return
        }

        var typeCounts: [String: Int] = [:]
        for event in toCompact {
            typeCounts[event.type, default: 0] += 1
        }

        let summary = typeCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        let semanticLines = semanticSummaryLines(from: compactionCandidates)
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
        logCompactionIfNeeded(
            start: start,
            taskID: task.id,
            eventCount: events.count,
            compactedCount: toCompact.count,
            keptCount: events.count - toCompact.count,
            reconstructionCriticalCount: reconstructionCriticalIDs.count,
            summaryEventInserted: true
        )
    }

    private static func logCompactionIfNeeded(
        start: UInt64,
        taskID: UUID,
        eventCount: Int,
        compactedCount: Int,
        keptCount: Int,
        reconstructionCriticalCount: Int,
        summaryEventInserted: Bool
    ) {
        PerformanceTelemetry.logIfNeeded(
            "event_compaction",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.backgroundThresholdMilliseconds,
            fields: [
                "task_id": PerformanceTelemetryFields.abbreviatedID(taskID),
                "event_count": PerformanceTelemetryFields.count(eventCount),
                "compacted_count": PerformanceTelemetryFields.count(compactedCount),
                "kept_count": PerformanceTelemetryFields.count(keptCount),
                "reconstruction_critical_count": PerformanceTelemetryFields.count(reconstructionCriticalCount),
                "summary_event_inserted": PerformanceTelemetryFields.bool(summaryEventInserted)
            ]
        )
    }

    /// IDs of the most recent reconstructed-lifecycle event for each grouping key
    /// present in `events`, exempted from deletion so the derived state that feeds
    /// the prompt still rebuilds after compaction. Grouping is per-entity, matching
    /// how the consumers read the log:
    /// - validation assertion events → latest per `(planID, assertionID)`
    ///   (mirrors the Context Capsule's `latestAssertionEventsByID(task:planID:)`),
    /// - validation contract events → latest per `(planID, type)`,
    /// - corrective step events → latest per `correctiveStepID`
    ///   (mirrors `TaskCorrectiveWorkService.latestCorrectiveSteps`),
    /// - everything else (plan lifecycle, verifier, handoff) → latest per type.
    /// Bounded by the number of distinct assertions/steps/types, so high-volume
    /// `plan.step.*` streams still compact while per-assertion status survives.
    private static func latestReconstructedEventIDs(in events: [TaskEvent]) -> Set<UUID> {
        var latestByKey: [String: TaskEvent] = [:]
        for event in events where isReconstructedLifecycleEvent(event) {
            let key = reconstructionGroupingKey(for: event)
            // `events` is sorted ascending by timestamp, so a strict `>` keeps the
            // last-seen (latest) event on a timestamp tie.
            if let existing = latestByKey[key], existing.timestamp > event.timestamp {
                continue
            }
            latestByKey[key] = event
        }
        return Set(latestByKey.values.map(\.id))
    }

    private static func latestOutputPresentationAnchorIDs(in events: [TaskEvent]) -> Set<UUID> {
        let grouped = Dictionary(grouping: events.filter { isOutputPresentationEvent($0) }) { event in
            event.run?.id.uuidString ?? "task"
        }
        var output = Set<UUID>()
        for runEvents in grouped.values {
            let sorted = runEvents.sorted { $0.timestamp < $1.timestamp }
            guard let latestBoundaryIndex = sorted.lastIndex(where: isOutputPresentationBoundaryEvent) else {
                if let latestResponse = sorted.last(where: { $0.type == "agent.response" }) {
                    output.insert(latestResponse.id)
                }
                continue
            }

            output.insert(sorted[latestBoundaryIndex].id)
            let finalResponses = sorted
                .dropFirst(latestBoundaryIndex + 1)
                .filter { $0.type == "agent.response" }
            guard finalResponses.count <= maxPreservedFinalResponseChunks else {
                output.remove(sorted[latestBoundaryIndex].id)
                continue
            }
            for event in finalResponses {
                output.insert(event.id)
            }
        }
        return output
    }

    private static func isOutputPresentationEvent(_ event: TaskEvent) -> Bool {
        event.type == "agent.response" || isOutputPresentationBoundaryEvent(event)
    }

    private static func isOutputPresentationBoundaryEvent(_ event: TaskEvent) -> Bool {
        switch event.type {
        case "tool.use", "tool.result", "permission.denied", "permission.approval.requested":
            return true
        default:
            return false
        }
    }

    private static func isReconstructedLifecycleEvent(_ event: TaskEvent) -> Bool {
        reconstructedEventTypePrefixes.contains { event.type.hasPrefix($0) }
    }

    /// Per-entity key used to decide which reconstructed events to keep. Reuses the
    /// same decoders the consumers use, so a preserved event keys identically to how
    /// it will later be read. Falls back to the event type when the payload can't be
    /// decoded (still preserved as latest-of-type).
    private static func reconstructionGroupingKey(for event: TaskEvent) -> String {
        if validationAssertionEventTypes.contains(event.type),
           case let .success(payload) = ValidationService.decodeAssertionPayloadResult(event.payload) {
            return "assertion:\(payload.planID.uuidString):\(payload.assertionID)"
        }
        if validationContractEventTypes.contains(event.type),
           let planID = decodeContractPlanID(event.payload) {
            return "contract:\(planID):\(event.type)"
        }
        if event.type.hasPrefix("corrective."),
           let payload = TaskCorrectiveWorkQueries.decode(event.payload) {
            return "corrective:\(TaskCorrectiveWorkQueries.normalizedCorrectiveStepID(payload))"
        }
        return event.type
    }

    private static func decodeContractPlanID(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TaskValidationContractEventPayload.self, from: data) else {
            return nil
        }
        return decoded.planID.uuidString
    }

    private static func shouldPreserveDuringCompaction(_ event: TaskEvent) -> Bool {
        if event.type.hasPrefix("astra.") {
            return true
        }

        switch event.type {
        case "user.message",
             "objective.assessment.changed",
             "schedule.result",
             "system.info",
             "recap.result",
             "budget.warning",
             "budget.exceeded",
             "permission.denied",
             "permission.approval.requested",
             "permission.request.resolved",
             "runtime.docker_image_recovery",
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
