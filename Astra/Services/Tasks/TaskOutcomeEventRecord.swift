import Foundation
import ASTRAModels

/// The five event fields the outcome resolvers read, so one rule can run over
/// SwiftData rows in a service and over transcript snapshots in a view.
///
/// Resolving from `AgentTask.events` faults every event in the task through
/// `performAndWait` — fine once at a run boundary, ruinous on every SwiftUI
/// body pass. The transcript already holds these fields for the same events;
/// this is the seam that lets a view hand them over instead of re-faulting.
struct TaskOutcomeEventRecord: Equatable, Sendable {
    let id: UUID
    let runID: UUID?
    let type: String
    let payload: String
    let timestamp: Date

    init(id: UUID, runID: UUID?, type: String, payload: String, timestamp: Date) {
        self.id = id
        self.runID = runID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }

    @MainActor
    init(event: TaskEvent) {
        self.init(
            id: event.id,
            runID: event.run?.id,
            type: event.type,
            payload: event.payload,
            timestamp: event.timestamp
        )
    }

    static func isChronologicallyOrdered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
