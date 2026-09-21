import Foundation
import ASTRACore
import ASTRAModels

/// Refresh entry points for `TaskContextStateManager`.
///
/// Kept beside the manager rather than inside it: that file is at its
/// line-budget ceiling, and these are the two callers' doorways into it rather
/// than part of its core.
extension TaskContextStateManager {
    /// What the off-actor half of a refresh produces.
    private struct LoadedContextState: Sendable {
        let folder: String
        let existing: TaskContextState?
    }

    /// `refresh(task:)` with its filesystem work moved off the main actor.
    ///
    /// `refresh` resolves the task folder — which runs a legacy-layout
    /// migration check and creates two directories — and then reads and
    /// decodes `current_state.json`, all before it touches any model state. On
    /// task open that whole sequence runs on the main thread, and production
    /// samples of the `context_state_refresh` phase put it at p50 60 ms, p90
    /// 178 ms, max 706 ms — a freeze the user feels when selecting a task.
    ///
    /// Both steps are pure functions of a workspace path and a task id, so
    /// they move off-actor unchanged. Everything that reads the SwiftData
    /// model stays on the main actor in `applyRefresh`, and the save stays
    /// there too, so durability ordering is untouched — and the common
    /// task-open case is a no-op refresh that never saves at all.
    ///
    /// `refresh(task:)` itself is deliberately left alone: it is the durable
    /// launch path, where callers depend on the write having happened by the
    /// time it returns.
    @MainActor
    public static func refreshLoadingOffMainActor(task: AgentTask, followUpMessage: String = "") async {
        // Read off the model before leaving the actor; the detached work takes
        // only sendable values.
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedContextState? in
            guard let folder = try? TaskFolderResolvingAdapter.ensureTaskFolder(
                workspacePath: workspacePath,
                taskID: taskID
            ), !folder.isEmpty else { return nil }
            return LoadedContextState(
                folder: folder,
                existing: TaskContextStateRecovery.recoverState(taskFolder: folder, taskID: taskID)
            )
        }.value
        guard let loaded else { return }
        applyRefresh(
            existing: loaded.existing,
            folder: loaded.folder,
            task: task,
            followUpMessage: followUpMessage
        )
    }

    @MainActor
    public static func refreshedPromptContext(for task: AgentTask, followUpMessage: String = "") -> String? {
        refresh(task: task, followUpMessage: followUpMessage)
        return promptContext(for: task)
    }
}
