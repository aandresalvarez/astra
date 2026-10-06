import Foundation
import ASTRACore
import ASTRAModels

/// The single writer for "where the next task runs": a draft's pin when a
/// draft is given, otherwise the workspace default new tasks start from. The
/// Repository card and the new-task worktree strip both write through here,
/// so they always describe the same checkout.
@MainActor
enum TaskCodeLocationPin {
    static let reservedCheckoutMessage = "That checkout is being removed and cannot be selected."

    /// Stores `path`. For the workspace default, nil or the primary path clears
    /// the override so new tasks follow the primary checkout. A draft keeps an
    /// explicit path, including the primary repository: nil on a draft means
    /// the draft has not chosen and still follows the workspace default.
    /// Returns true when the stored value changed.
    @discardableResult
    static func set(_ path: String?, workspace: Workspace, task: AgentTask?) -> Bool {
        let normalized = normalize(path)
        let primary = WorkspacePathPresentation.standardizedPath(workspace.primaryPath)
        let stored = task == nil && normalized == primary ? nil : normalized
        // Cleanup owns this path until removal finishes. Refusing the write
        // is what keeps a task from being pinned to a checkout that is going
        // away and then falling back to the source repository.
        guard !TaskWorktreeCheckoutReservation.isReserved(stored) else { return false }
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
