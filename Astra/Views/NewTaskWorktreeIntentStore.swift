import SwiftUI
import ASTRAModels

/// The new-task composer's live worktree choice, shared with the Repository
/// card so both describe the same "where the next task runs". The composer on
/// screen owns the single entry; nothing here is persisted. The durable
/// copies are the draft's `task.worktree.requested` event and, once created,
/// the worktree pin.
@MainActor
@Observable
final class NewTaskWorktreeIntentStore {
    struct Entry {
        let owner: UUID
        var workspaceID: UUID
        var draftID: UUID?
        var isEnabled = false
        var base: TaskWorktreeBaseChoice = .defaultBranch
        var baseLabel: String?
        /// A brand-new composer's draft once planning created its worktree.
        /// The card follows it although the scene has not selected it.
        var preparedDraft: AgentTask?
    }

    private(set) var entry: Entry?

    func claim(owner: UUID, workspaceID: UUID, draftID: UUID?) {
        entry = Entry(owner: owner, workspaceID: workspaceID, draftID: draftID)
    }

    func update(owner: UUID, _ change: (inout Entry) -> Void) {
        guard var current = entry, current.owner == owner else { return }
        change(&current)
        entry = current
    }

    /// A composer leaving the screen releases only its own entry, so a
    /// replacement that claimed first keeps its choice.
    func release(owner: UUID) {
        guard entry?.owner == owner else { return }
        entry = nil
    }

    /// The entry that describes the card's context: the new-task composer of
    /// this workspace when no task is selected, or the selected draft's own
    /// composer.
    func entry(workspaceID: UUID, selectedTaskID: UUID?) -> Entry? {
        guard let entry, entry.workspaceID == workspaceID else { return nil }
        guard let selectedTaskID else { return entry }
        return entry.draftID == selectedTaskID ? entry : nil
    }
}

private struct NewTaskWorktreeIntentStoreKey: EnvironmentKey {
    static let defaultValue: NewTaskWorktreeIntentStore? = nil
}

extension EnvironmentValues {
    var newTaskWorktreeIntents: NewTaskWorktreeIntentStore? {
        get { self[NewTaskWorktreeIntentStoreKey.self] }
        set { self[NewTaskWorktreeIntentStoreKey.self] = newValue }
    }
}
