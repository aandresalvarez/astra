import Foundation
import SwiftData

/// Reads only the rows a rule needs, through the caller's model context.
/// SwiftData owns pending changes, rollback and run state; no mutable mirror
/// can authorize a turn or select a checkout using an obsolete value.
///
/// Filtering in the store avoids faulting every tool event on every read.
/// Imported copies may share UUIDs, so a UUID narrows the query but the
/// persistent owner decides which rows belong to this task.
public enum TaskHistoryRead {
    /// A launch snapshot needs every event, including agent metadata. Fetch
    /// them together instead of faulting the relationship one row at a time.
    public static func events(for task: AgentTask) -> [TaskEvent] {
        let taskID = task.id
        return events(task: task, predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID
        }, matches: { _ in true })
    }

    public static func events(for task: AgentTask, ofTypes types: Set<String>) -> [TaskEvent] {
        let taskID = task.id
        let values = Array(types)
        return events(task: task, predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID && values.contains($0.type)
        }, matches: { types.contains($0.type) })
    }

    /// Prefix rules intentionally include future execution-request event kinds.
    public static func events(for task: AgentTask, ofTypes types: Set<String>, orTypePrefix prefix: String) -> [TaskEvent] {
        let taskID = task.id
        let values = Array(types)
        return events(task: task, predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID && (values.contains($0.type) || $0.type.starts(with: prefix))
        }, matches: { types.contains($0.type) || $0.type.hasPrefix(prefix) })
    }

    /// Legacy payloads without a run binding still need their latest saved or
    /// pending occurrence, without faulting unrelated tool output into the UI.
    public static func events(for task: AgentTask, matchingPayload payload: String) -> [TaskEvent] {
        let taskID = task.id
        return events(task: task, predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.payload == payload
        }, matches: { $0.payload == payload })
    }

    /// A run summary needs all of that run's event kinds, including future
    /// provider evidence, without loading unrelated turns.
    public static func events(for task: AgentTask, runID: UUID) -> [TaskEvent] {
        let taskID = task.id
        return events(task: task, predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.run?.id == runID
        }, matches: { $0.run?.id == runID })
    }

    public static func records(for task: AgentTask, ofTypes types: Set<String>) -> [TaskEventRecord] {
        events(for: task, ofTypes: types)
            .map(TaskEventRecord.init(event:))
            .sorted(by: TaskEventRecord.isChronologicallyOrdered)
    }

    public static func event(id eventID: UUID, in task: AgentTask) -> TaskEvent? {
        let taskID = task.id
        return events(task: task, predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.id == eventID
        }, matches: { $0.id == eventID }).first
    }

    public static func record(id eventID: UUID, in task: AgentTask) -> TaskEventRecord? {
        event(id: eventID, in: task).map(TaskEventRecord.init(event:))
    }

    public static func contains(eventID: UUID, in task: AgentTask) -> Bool {
        event(id: eventID, in: task) != nil
    }

    public static func runs(for task: AgentTask) -> [TaskRunRecord] {
        let taskID = task.id
        let owner = task.persistentModelID
        let descriptor = FetchDescriptor<TaskRun>(predicate: #Predicate { $0.task?.id == taskID })
        let rows = task.modelContext.flatMap { try? $0.fetch(descriptor) } ?? task.runs
        return rows.filter { !$0.isDeleted && $0.task?.persistentModelID == owner }.map {
            TaskRunRecord(id: $0.id, startedAt: $0.startedAt, runStatus: $0.status, stopReason: $0.stopReason)
        }
    }

    private static func events(
        task: AgentTask,
        predicate: Predicate<TaskEvent>,
        matches: (TaskEvent) -> Bool
    ) -> [TaskEvent] {
        let owner = task.persistentModelID
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.relationshipKeyPathsForPrefetching = [\TaskEvent.run]
        guard let context = task.modelContext,
              let rows = try? context.fetch(descriptor) else {
            return task.events.filter { !$0.isDeleted && matches($0) }
        }
        return rows.filter { !$0.isDeleted && $0.task?.persistentModelID == owner && matches($0) }
    }
}
