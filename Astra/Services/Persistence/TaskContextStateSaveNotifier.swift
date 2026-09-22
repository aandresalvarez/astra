import Foundation

extension Notification.Name {
    /// Posted after `TaskContextStateManager.saveState` writes a task's
    /// `current_state.json`. The object is a `TaskContextStateSave`.
    public static let taskContextStateDidSave = Notification.Name("astra.taskContextStateDidSave")
}

/// Names the task whose `current_state.json` was just written.
///
/// The file is derived state that views read from disk, and nothing a view
/// can observe moves exactly when it changes. `task.updatedAt` comes closest,
/// but every runtime event bumps it — several times a second while a run
/// streams — and the file changes a handful of times a run. Every writer
/// (`recordTurn` at the end of a run, `refresh` after plan, validation and
/// mission events, the objective assessment) goes through `saveState`, so that
/// is where a cache learns its copy is stale. See `TaskMissionControlSnapshot`.
public struct TaskContextStateSave: Equatable, Sendable {
    public let taskID: UUID

    public init(taskID: UUID) {
        self.taskID = taskID
    }
}

enum TaskContextStateSaveNotifier {
    static func post(_ result: TaskContextStateSaveResult, taskID: UUID?) {
        // A failed write left the previous file in place, and a save with no
        // task id has no view to tell.
        guard result.didSave, let taskID else { return }
        NotificationCenter.default.post(
            name: .taskContextStateDidSave,
            object: TaskContextStateSave(taskID: taskID)
        )
    }
}
