import Foundation
import SwiftData
import ASTRAModels
import HostControlToolSupport

/// A fresh read-only context per broker call, on the broker's connection queue.
/// Only value dictionaries escape. The task binding comes from ASTRA's launch,
/// never from provider arguments. No projection files or mutable cache exist.
final class TaskHistoryEvidenceReader: TaskHistoryReading, @unchecked Sendable {
    private let container: ModelContainer
    private let taskID: UUID
    init(container: ModelContainer, taskID: UUID) {
        self.container = container
        self.taskID = taskID
    }

    func readHistory(_ request: TaskHistoryReadRequest) throws -> [String: Any] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let taskID = taskID
        // Recovery envelopes are private implementation state, not conversation
        // evidence, and may include launch configuration or captured credentials.
        let captured = TaskEventTypes.System.runtimeResultCaptured.rawValue
        let prepared = TaskEventTypes.System.runtimeOutcomePrepared.rawValue
        let base = #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.type != captured && $0.type != prepared
        }
        func event(_ id: UUID) throws -> TaskEvent {
            var descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && $0.type != captured && $0.type != prepared && $0.id == id
            })
            descriptor.fetchLimit = 1
            guard let value = try context.fetch(descriptor).first else {
                throw NSError(domain: "ASTRAHistory", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found in this task's readable history."])
            }
            return value
        }
        if let id = request.eventID {
            return snapshot(try event(id), offset: request.offset, limit: 4_000)
        }
        var predicate = base
        if let id = request.beforeID {
            let boundary = try event(id)
            let timestamp = boundary.timestamp
            predicate = #Predicate<TaskEvent> {
                $0.task?.id == taskID && $0.type != captured && $0.type != prepared
                    && ($0.timestamp < timestamp || ($0.timestamp == timestamp && $0.id < id))
            }
        }
        var descriptor = FetchDescriptor<TaskEvent>(predicate: predicate,
            sortBy: [SortDescriptor(\TaskEvent.timestamp, order: .reverse), SortDescriptor(\TaskEvent.id, order: .reverse)])
        descriptor.fetchLimit = 11
        let rows = try context.fetch(descriptor)
        let page = Array(rows.prefix(10))
        var result: [String: Any] = ["task_id": taskID.uuidString,
            "events": page.map { snapshot($0, offset: 0, limit: 1_000) }, "has_older": rows.count > 10]
        if rows.count > 10, let last = page.last { result["next_before_id"] = last.id.uuidString }
        return result
    }

    private func snapshot(_ event: TaskEvent, offset: Int, limit: Int) -> [String: Any] {
        let payload = String(event.payload.dropFirst(offset).prefix(limit))
        let next = offset + payload.count
        var result: [String: Any] = ["id": event.id.uuidString, "task_id": taskID.uuidString,
            "type": event.type, "timestamp": event.timestamp.timeIntervalSince1970,
            "category": event.category, "payload": payload, "offset": offset,
            "payload_characters": event.payload.count, "payload_truncated": next < event.payload.count]
        if next < event.payload.count { result["next_offset"] = next }
        if let run = event.run { result["run_id"] = run.id.uuidString }
        if let name = event.agentName { result["agent_name"] = name }
        if let id = event.agentId { result["agent_id"] = id }
        if let team = event.teamName { result["team_name"] = team }
        return result
    }
}
