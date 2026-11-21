import Foundation

/// Whether a workspace's new-task composer starts with "Start in a new
/// worktree" checked. Off unless a person turned it on for that workspace.
///
/// It is a preference about a starting value, per workspace on this Mac. What
/// a task actually does is still owned by its `task.worktree.requested` event
/// and, once the worktree exists, by its pin; this value is read once when a
/// fresh composer has a repository to offer and is never written by a run.
///
/// Kept in `UserDefaults`, like the other per-workspace interface
/// preferences (`RailDisclosureStore`, `PluginsSurfacePreferences`): it needs
/// no schema version, and it is not exported with the workspace.
enum NewTaskWorktreeDefaultStore {
    /// On-disk key. Do not rename without a migration.
    private static func key(_ workspaceID: UUID) -> String {
        "newTaskWorktree.startsEnabled.\(workspaceID.uuidString)"
    }

    static func startsEnabled(workspaceID: UUID, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(workspaceID))
    }

    /// Off removes the key, so a workspace nobody configured and one that was
    /// turned off again are the same.
    static func setStartsEnabled(_ value: Bool, workspaceID: UUID, in defaults: UserDefaults = .standard) {
        if value {
            defaults.set(true, forKey: key(workspaceID))
        } else {
            defaults.removeObject(forKey: key(workspaceID))
        }
    }
}
