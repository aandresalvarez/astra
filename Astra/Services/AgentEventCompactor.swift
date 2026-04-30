import Foundation
import SwiftData

enum AgentEventCompactor {
    static let threshold = 200
    static let keepCount = 50

    @MainActor
    static func compactEvents(for task: AgentTask, modelContext: ModelContext) {
        let events = task.events.sorted { $0.timestamp < $1.timestamp }
        guard events.count > threshold else { return }

        let cutoff = events.count - keepCount
        let toCompact = events
            .prefix(cutoff)
            .filter { !$0.type.hasPrefix("astra.") }
        guard !toCompact.isEmpty else { return }

        var typeCounts: [String: Int] = [:]
        for event in toCompact {
            typeCounts[event.type, default: 0] += 1
        }

        let summary = typeCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")

        let summaryEvent = TaskEvent(
            task: task,
            type: "activity.compacted",
            payload: "Compacted \(toCompact.count) earlier events. Breakdown: \(summary)"
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
}
