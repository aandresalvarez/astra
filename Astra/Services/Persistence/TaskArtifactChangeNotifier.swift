import Foundation

extension Notification.Name {
    /// Posted on the main actor after `TaskArtifactPersistenceService` adds or
    /// rewrites a task's artifact rows. The object is a `TaskArtifactsChange`.
    public static let taskArtifactsDidChange = Notification.Name("astra.taskArtifactsDidChange")
}

/// Names the task whose artifact rows just changed.
///
/// `TaskGeneratedFilesTrigger` used to notice this by counting `task.artifacts`
/// while `TaskMainView.body` ran, which meant a relationship fault on every
/// keystroke in the composer. Every row an existing task gains comes through
/// `TaskArtifactPersistenceService` (the run-finalize reconcile, the live
/// file-change recorder and detector, deliverable verification), and nothing
/// deletes one, so the service is where the view hears about it instead.
public struct TaskArtifactsChange: Equatable, Sendable {
    public let taskID: UUID

    public init(taskID: UUID) {
        self.taskID = taskID
    }
}

@MainActor
enum TaskArtifactChangeNotifier {
    static func post(taskID: UUID) {
        NotificationCenter.default.post(
            name: .taskArtifactsDidChange,
            object: TaskArtifactsChange(taskID: taskID)
        )
    }
}
