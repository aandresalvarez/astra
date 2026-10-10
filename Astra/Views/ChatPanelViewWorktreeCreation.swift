import Foundation
import SwiftUI
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The new-task composer's worktree creation: which draft's checkout a new
/// task takes, the one creation that may run at a time, cancelling it, and
/// the cached worktree binding `body` reads. `ChatPanelView` owns the state;
/// the durable steps live in `NewTaskWorktreeComposerFlow` and
/// `TaskWorktreeService`.
extension ChatPanelView {
    var isPreparingWorktree: Bool { taskCreation.isPreparing }

    var composerDraft: AgentTask? {
        NewTaskWorktreeComposerFlow.liveDraft(draftTask, in: workspace)
            ?? NewTaskWorktreeComposerFlow.liveDraft(draftToLoad, in: workspace)
    }

    var worktreeBinding: TaskWorktreePayload? { cachedWorktreeBinding }

    /// Everything the binding depends on, read from the model only.
    struct WorktreeBindingSignature: Equatable {
        var draftID: UUID?
        var pin: String?
        var preparedEventID: UUID?
    }

    var worktreeBindingSignature: WorktreeBindingSignature {
        let draft = composerDraft
        return WorktreeBindingSignature(
            draftID: draft?.id,
            pin: draft?.executionRootPath,
            preparedEventID: draft.flatMap(TaskWorktreeBinding.eventForInheritance(from:))?.id
        )
    }

    func refreshWorktreeBinding() {
        cachedWorktreeBinding = composerDraft.flatMap(TaskWorktreeService.activeWorktreeBinding)
    }

    /// A draft that already has its worktree keeps it; anything else may opt in.
    var allowsWorktreeChoice: Bool { worktreeBinding == nil }

    /// The worktree the next planning step or run creates, if any.
    var requestedWorktree: TaskWorktreeRequest? {
        allowsWorktreeChoice ? worktreeSelection.request : nil
    }

    var canSubmitWorktreeSelection: Bool {
        !allowsWorktreeChoice || worktreeSelection.canSubmit
    }

    func reportTaskCreationError(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        taskCreationError = error.localizedDescription
        AppLogger.error("Task creation failed: \(error.localizedDescription)", category: "UI")
    }

    /// Stops waiting for the creation or planning preparation in flight and
    /// frees the composer. A Git operation that already finished leaves the
    /// draft bound to its worktree, which the composer then shows.
    func cancelTaskCreation() {
        chatReplyTask?.cancel()
        planGenerationTask?.cancel()
        taskCreation.detach()
        isThinking = false
        taskCreationError = nil
    }

    func performTaskCreation(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isPreparingWorktree, !isThinking else { return }
        guard canSubmitWorktreeSelection else {
            return taskCreationError = worktreeSelection.submitError.localizedDescription
        }
        taskCreationError = nil
        taskCreation.start(action, onError: reportTaskCreationError)
    }

    func prepareTaskCheckout(_ task: AgentTask) async throws {
        guard canSubmitWorktreeSelection else {
            throw worktreeSelection.submitError
        }
        let draft = composerDraft
        let request = requestedWorktree
        do {
            if draft == nil, request != nil { try NewTaskWorktreeComposerFlow.keepConversation(messages, on: task) }
            try await TaskWorktreeService.prepare(
                task: task,
                request: request,
                inheritingFrom: NewTaskWorktreeComposerFlow.checkoutSource(draft: draft, isSelectedDraft: draftToLoad != nil),
                modelContext: modelContext, resourceQueue: taskQueue
            )
            try Task.checkCancellation()
        } catch {
            // A completed Git operation may already have saved the task with its
            // worktree. The draft keeps that worktree for retry, never a second one.
            if task.modelContext != nil {
                let recovered = try TaskWorktreeService.recoverFailedSubmission(
                    task: task, existingDraft: draft, modelContext: modelContext
                )
                // A cancelled creation's draft returns to this composer; one
                // detached by a workspace switch stays with the workspace it
                // began in.
                if recovered == nil || recovered?.workspace?.id == workspace?.id { draftTask = recovered }
            }
            throw error
        }
    }

    /// Planning reads the code the task will run in, so a requested worktree
    /// is created for the draft before the planner first runs.
    func ensurePlanningWorktree(for draft: AgentTask, branchTitle: String? = nil) async throws {
        guard let request = requestedWorktree else { return }
        try await taskCreation.preparing {
            try await TaskWorktreeService.prepare(
                task: draft, request: request, branchTitle: branchTitle, modelContext: modelContext, resourceQueue: taskQueue
            )
        }
        try Task.checkCancellation()
    }

    /// Template tasks take the checkout a quick run would; the conversation's
    /// draft holds a requested worktree for them.
    func templateCheckoutSource(branchTitle: String) async throws -> AgentTask? {
        guard requestedWorktree != nil else {
            return NewTaskWorktreeComposerFlow.checkoutSource(draft: composerDraft, isSelectedDraft: draftToLoad != nil)
        }
        guard let draft = try await saveDraft() else { throw TaskWorktreeCreationError.noDraft }
        try await ensurePlanningWorktree(for: draft, branchTitle: branchTitle)
        return draft
    }
}
