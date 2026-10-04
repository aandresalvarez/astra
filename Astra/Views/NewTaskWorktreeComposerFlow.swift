import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The new-task composer's worktree steps. `ChatPanelView` decides when they
/// run; the durable state stays with `TaskWorktreeService` and the draft.
///
/// A worktree is created lazily: when the task starts, or when Goal Mode
/// planning first reads the code. Plain chats never create one.
@MainActor
enum NewTaskWorktreeComposerFlow {
    /// The composer's draft, unless it is gone (deleted or promoted).
    static func liveDraft(_ draft: AgentTask?) -> AgentTask? {
        guard let draft, draft.modelContext != nil, !draft.isDeleted else { return nil }
        return draft
    }

    /// The draft a task created from the composer takes its checkout from. A
    /// draft the scene selected follows its own pin, and a draft with its own
    /// worktree hands it over. A brand-new draft does neither: like the task,
    /// it follows the workspace default.
    static func checkoutSource(draft: AgentTask?, isSelectedDraft: Bool) -> AgentTask? {
        guard let draft else { return nil }
        if isSelectedDraft || TaskWorktreeService.activeWorktreeBinding(for: draft) != nil { return draft }
        return nil
    }

    /// Keeps a brand-new draft without a worktree on the workspace default,
    /// so planning reads the checkout the task will run in.
    static func followWorkspaceDefault(_ draft: AgentTask, workspace: Workspace?) {
        guard let workspace, TaskWorktreeService.activeWorktreeBinding(for: draft) == nil else { return }
        TaskCodeLocationPin.set(workspace.activeWorkingPath, workspace: workspace, task: draft)
    }

    /// Records the worktree choice on the draft so reopening it restores the
    /// checkbox and base. A draft that has its worktree no longer has a choice.
    static func recordChoice(
        _ selection: NewTaskWorktreeSelection,
        on draft: AgentTask,
        modelContext: ModelContext
    ) {
        guard TaskWorktreeService.activeWorktreeBinding(for: draft) == nil else { return }
        TaskWorktreeService.recordRequestIfChanged(selection.requestPayload, on: draft, modelContext: modelContext)
    }

    static func restoreChoice(_ selection: inout NewTaskWorktreeSelection, from draft: AgentTask) {
        guard let request = TaskWorktreeService.latestRequest(for: draft) else { return }
        selection.isEnabled = request.enabled
        selection.base = request.base
    }

    /// After a discarded draft is deleted, saves the deletion and removes its
    /// worktree if nothing happened in it.
    static func discardWorktree(
        _ worktree: TaskWorktreeDiscard?,
        workspace: Workspace?,
        modelContext: ModelContext
    ) {
        guard let worktree else { return }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        Task { @MainActor in
            await TaskWorktreeService.discardUnusedWorktree(worktree, modelContext: modelContext)
        }
    }
}
