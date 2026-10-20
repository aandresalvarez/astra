import Foundation
import SwiftData
import ASTRAModels

/// Reads a task's events of a few known types without touching the rest.
///
/// The settlement protocol looks up its own boundary events — result captured,
/// settlement started, outcome prepared, turn settled — several times per turn,
/// and each lookup used to be a `task.events` scan. SwiftData hands the
/// relationship back as faults after every save, so on a long task each scan
/// that followed a save fired one row fetch per event: about 2 000 on the task
/// this was measured on, repeated after each of the six saves a turn makes.
/// A predicate fetch reads only the matching rows, in one query.
///
/// The fetch includes unsaved inserts and excludes unsaved deletions, which is
/// what the `!isDeleted` scans it replaces looked at. An unmanaged task (a
/// detached launch view, or one never inserted) has no store to ask, so it is
/// scanned as before.
///
/// `task.id` narrows the query but does not decide ownership: importing a
/// workspace as a duplicate restores the exported task and run UUIDs, so two
/// live tasks can share one. Each row is kept only if its owner is this task's
/// own persistent identity, which is what the relationship scan answered.
@MainActor
public enum TaskEventTypeLookup {
    public static func events(ofType type: String, task: AgentTask) -> [TaskEvent] {
        let taskID = task.id
        return fetch(task: task, #Predicate<TaskEvent> { $0.task?.id == taskID && $0.type == type }) {
            $0.type == type
        }
    }

    /// The events of `type` recorded against `run`.
    public static func events(ofType type: String, task: AgentTask, run: TaskRun) -> [TaskEvent] {
        let taskID = task.id
        let runID = run.id
        return fetch(task: task, #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.type == type && $0.run?.id == runID
        }) {
            $0.type == type && $0.run?.id == runID
        }
    }

    public static func first(ofType type: String, task: AgentTask, run: TaskRun) -> TaskEvent? {
        events(ofType: type, task: task, run: run).first
    }

    /// `scan` is the same condition as `predicate`, for the tasks no store can
    /// answer for.
    private static func fetch(
        task: AgentTask,
        _ predicate: Predicate<TaskEvent>,
        scan: (TaskEvent) -> Bool
    ) -> [TaskEvent] {
        guard let modelContext = task.modelContext,
              let fetched = try? modelContext.fetch(FetchDescriptor<TaskEvent>(predicate: predicate)) else {
            return task.events.filter { !$0.isDeleted && scan($0) }
        }
        let owner = task.persistentModelID
        return fetched.filter { !$0.isDeleted && $0.task?.persistentModelID == owner }
    }
}
