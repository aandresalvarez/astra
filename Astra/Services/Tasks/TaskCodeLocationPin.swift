import Foundation
import ASTRACore
import ASTRAModels

/// The single writer for "where the next task runs": a draft's pin when a
/// draft is given, otherwise the workspace default new tasks start from. The
/// Repository card and the new-task worktree strip both write through here,
/// so they always describe the same checkout.
@MainActor
enum TaskCodeLocationPin {
    /// Stores `path`; nil or the workspace's primary path clears the override.
    /// Returns true when the stored value changed.
    @discardableResult
    static func set(_ path: String?, workspace: Workspace, task: AgentTask?) -> Bool {
        let normalized = normalize(path)
        let stored = normalized == WorkspacePathPresentation.standardizedPath(workspace.primaryPath)
            ? nil
            : normalized
        // Skip no-op writes so reselecting the same checkout (or a scan) never
        // bumps updatedAt or marks the model dirty.
        if let task {
            guard task.executionRootPath != stored else { return false }
            task.executionRootPath = stored
            task.updatedAt = Date()
        } else {
            guard workspace.activeWorkingPath != stored else { return false }
            workspace.activeWorkingPath = stored
            workspace.updatedAt = Date()
        }
        return true
    }

    static func normalize(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WorkspacePathPresentation.standardizedPath(path)
    }
}
