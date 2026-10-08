import Foundation
import Observation
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
    /// The composer's draft, if it still exists in the selected workspace.
    static func liveDraft(_ draft: AgentTask?, in workspace: Workspace?) -> AgentTask? {
        guard let draft, draft.modelContext != nil, !draft.isDeleted,
              draft.workspace?.id == workspace?.id else { return nil }
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

    /// Keeps a brand-new draft without a worktree on its workspace's default,
    /// so planning reads the checkout the task will run in. An explicit pin or
    /// a recorded repository is left alone.
    static func followWorkspaceDefault(_ draft: AgentTask) {
        guard let workspace = draft.workspace,
              case .none = TaskWorktreeBinding.state(of: draft),
              draft.executionRootPath?.isEmpty != false else { return }
        if let request = TaskWorktreeService.latestRequest(for: draft),
           request.enabled {
            if let checkout = request.checkoutPath, !checkout.isEmpty {
                TaskCodeLocationPin.set(checkout, workspace: workspace, task: draft)
                return
            }
            if let repository = request.repositoryPath, !repository.isEmpty {
                TaskCodeLocationPin.set(repository, workspace: workspace, task: draft)
                return
            }
        }
        TaskCodeLocationPin.set(workspace.activeWorkingPath, workspace: workspace, task: draft)
    }

    /// Records the worktree choice on the draft so reopening it restores the
    /// checkbox and base. A draft that has its worktree no longer has a choice.
    @discardableResult
    static func recordChoice(
        _ selection: NewTaskWorktreeSelection,
        on draft: AgentTask,
        modelContext: ModelContext
    ) -> Bool {
        guard TaskWorktreeService.activeWorktreeBinding(for: draft) == nil else { return false }
        return TaskWorktreeService.recordRequestIfChanged(selection.requestPayload, on: draft, modelContext: modelContext)
    }

    static func persistChoice(
        _ selection: NewTaskWorktreeSelection,
        on draft: AgentTask,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext) throws -> Void = { workspace, context in
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace, modelContext: context,
                auditFields: ["operation": "draft_worktree_choice_changed"]
            )
        }
    ) throws {
        guard draft.status == .draft else { return }
        let previousEvents = Set(draft.events.map(\.id))
        let previousUpdatedAt = draft.updatedAt
        guard recordChoice(selection, on: draft, modelContext: modelContext) else { return }
        do {
            try persist(draft.workspace, modelContext)
        } catch {
            for event in draft.events where event.hasType(TaskEventTypes.Task.worktreeRequested)
                && !previousEvents.contains(event.id) {
                modelContext.delete(event)
            }
            draft.updatedAt = previousUpdatedAt
            AppLogger.audit(.taskFailed, category: "Persistence", taskID: draft.id, fields: [
                "reason": "draft_worktree_choice_save_failed",
                "error": error.localizedDescription
            ], level: .error)
            throw TaskWorktreeCreationError.choicePersistenceFailed(error.localizedDescription)
        }
    }

    /// A task started straight from the composer into a new worktree keeps the
    /// conversation, so a failed launch can hand the worktree back as a draft.
    static func keepConversation(_ messages: [ChatMessage], on task: AgentTask) throws {
        guard task.draftMessages.isEmpty else { return }
        let history = messages.isEmpty
            ? [DraftChatMessagePayload(role: "user", content: task.goal)]
            : messages.map { DraftChatMessagePayload(role: $0.role, content: $0.content) }
        task.draftMessages = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
    }

    static func restoreChoice(_ selection: inout NewTaskWorktreeSelection, from draft: AgentTask) {
        guard let request = TaskWorktreeService.latestRequest(for: draft) else { return }
        selection.isEnabled = request.enabled
        selection.base = request.base
        if let repository = request.repositoryPath, !repository.isEmpty {
            selection.repositoryPath = WorkspacePathPresentation.standardizedPath(repository)
            // The draft's own checkout, never one left over from another draft.
            let checkout = request.checkoutPath.flatMap { $0.isEmpty ? nil : WorkspacePathPresentation.standardizedPath($0) }
            selection.checkoutPath = checkout
            selection.isCheckoutUnavailable = checkout.map { !FileManager.default.fileExists(atPath: $0) } ?? false
        }
    }

    /// After a discarded draft is deleted, saves the deletion and, once it is
    /// durable, removes each worktree nothing happened in. False when an
    /// intent or the deletion save failed; the draft is still present.
    @discardableResult
    static func discardWorktrees(
        _ worktrees: [TaskWorktreeDiscard],
        workspace: Workspace?,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        cleanupStore: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore(),
        delete: @MainActor () -> Void = {}
    ) -> Bool {
        TaskWorktreeService.saveDeletionThenDiscard(
            worktrees, workspace: workspace, modelContext: modelContext, resourceQueue: resourceQueue,
            cleanupStore: cleanupStore, delete: delete
        ).persisted
    }

    /// Deletes `draft` only when that deletion is saved. No draft is already
    /// a successful reset. Callers clear composer state only when this is true.
    /// Every worktree the draft prepared is given back, including one it was
    /// retargeted away from.
    @discardableResult
    static func discardDraft(
        _ draft: AgentTask?,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        cleanupStore: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore(),
        delete: @MainActor (AgentTask) -> Void
    ) -> Bool {
        guard let draft else { return true }
        return discardWorktrees(
            TaskWorktreeService.discardSnapshots(for: draft, ownership: cleanupStore.ownership),
            workspace: draft.workspace,
            modelContext: modelContext,
            resourceQueue: resourceQueue,
            cleanupStore: cleanupStore,
            delete: { delete(draft) }
        )
    }

    /// Deletes the draft `task` was created from. The worktree the task took
    /// over stays; any other the draft prepared, such as one it was retargeted
    /// away from or one from another workspace, is given back like a discarded
    /// draft's. False when the deletion wasn't saved; the draft is still present.
    @discardableResult
    static func discardPromotedDraft(
        _ draft: AgentTask,
        keeping task: AgentTask,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        cleanupStore: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore()
    ) -> Bool {
        let taskCheckout = task.executionRootPath.flatMap { $0.isEmpty ? nil : WorkspacePathPresentation.standardizedPath($0) }
        let unused = TaskWorktreeService.discardSnapshots(for: draft, ownership: cleanupStore.ownership).filter { discard in
            let worktree = WorkspacePathPresentation.standardizedPath(discard.worktreePath)
            guard let taskCheckout else { return true }
            return taskCheckout != worktree && !taskCheckout.hasPrefix(worktree + "/")
        }
        return discardWorktrees(
            unused,
            workspace: draft.workspace,
            modelContext: modelContext,
            resourceQueue: resourceQueue,
            cleanupStore: cleanupStore,
            delete: { modelContext.delete(draft) }
        )
    }

    /// Replaces `draft` with the task created from it. Throws while the
    /// draft's deletion isn't saved, so the caller keeps the composer, and the
    /// draft it shows, instead of reporting the task as created.
    static func promote(
        _ draft: AgentTask?,
        to task: AgentTask,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        cleanupStore: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore()
    ) throws {
        guard let draft, draft !== task else { return }
        guard discardPromotedDraft(
            draft, keeping: task, modelContext: modelContext, resourceQueue: resourceQueue, cleanupStore: cleanupStore
        ) else {
            throw NewTaskDraftPromotionError.draftNotRemoved
        }
    }
}

/// The task was saved, but the draft it was created from was not deleted.
enum NewTaskDraftPromotionError: LocalizedError, Equatable {
    case draftNotRemoved

    var errorDescription: String? {
        "ASTRA saved the task but could not remove the draft it came from, so the draft is still open here. Open the task from the task list to follow or run it, and delete the draft once you no longer need it."
    }
}

/// The composer's task creation, plus the worktrees planning prepares. One
/// creation runs at a time. A workspace switch detaches both, so work begun
/// for the previous workspace can no longer change the composer.
@MainActor
@Observable
final class NewTaskCreationRun {
    private var preparations: Set<UUID> = []
    @ObservationIgnored private var creation: (id: UUID, task: Task<Void, Never>)?

    var isPreparing: Bool { !preparations.isEmpty }

    /// Runs `action` unless a creation or preparation is in flight. Errors
    /// are reported only while the run is still attached.
    func start(
        _ action: @escaping @MainActor () async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard !isPreparing else { return }
        let id = UUID()
        preparations.insert(id)
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(id) }
            do {
                try await action()
            } catch {
                if !Task.isCancelled { onError(error) }
            }
        }
        creation = (id, task)
    }

    /// Shows `body` as worktree preparation, e.g. while planning creates one.
    func preparing(_ body: () async throws -> Void) async rethrows {
        let id = UUID()
        preparations.insert(id)
        defer { preparations.remove(id) }
        try await body()
    }

    /// Cancels the creation and stops waiting for it and any preparation, so
    /// the composer is free at once.
    func detach() {
        creation?.task.cancel()
        creation = nil
        preparations.removeAll()
    }

    private func finish(_ id: UUID) {
        preparations.remove(id)
        if creation?.id == id { creation = nil }
    }
}
