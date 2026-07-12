import Foundation
import SwiftData
import ASTRAModels

extension Notification.Name {
    static let durableTaskEventInserted = Notification.Name("astra.durableTaskEventInserted")
}

/// Typed, task-scoped value published at the durable event insertion boundary.
/// Consumers must still treat SwiftData as the source of truth; the payload is
/// a bounded projection used to invalidate presentation caches without loading
/// an entire event relationship.
struct DurableTaskEventInsertion: Equatable, Sendable {
    let taskID: UUID
    let eventID: UUID
    let type: String
    let payload: String
    let timestamp: Date

    init(taskID: UUID, eventID: UUID, type: String, payload: String, timestamp: Date) {
        self.taskID = taskID
        self.eventID = eventID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }
}

@MainActor
enum TaskEventInsertionService {
    static func insert(_ event: TaskEvent, into modelContext: ModelContext) {
        modelContext.insert(event)
        guard let taskID = event.task?.id else { return }
        let insertion = DurableTaskEventInsertion(
            taskID: taskID,
            eventID: event.id,
            type: event.type,
            payload: event.payload,
            timestamp: event.timestamp
        )
        NotificationCenter.default.post(name: .durableTaskEventInserted, object: insertion)
    }
}
