import SwiftUI
import SwiftData
import ASTRAModels

@MainActor
@Observable
final class TaskGitHubReviewPublicationState {
    var proposal: GitHubReviewProposal?
    var threadProposal: GitHubReviewThreadProposal?
    var preparationError: String?
    private(set) var isPreparing = false

    func prepare(task: AgentTask, filePaths: [String], modelContext: ModelContext) {
        guard !isPreparing else { return }
        isPreparing = true
        preparationError = nil
        Task { @MainActor in
            defer { isPreparing = false }
            // A thread proposal that cannot be used is dismissed by the service, so
            // it must not stop a review proposal from being offered.
            var threadError: Error?
            if GitHubReviewThreadPublicationService.pendingCandidatePath(task: task, filePaths: filePaths) != nil {
                do {
                    threadProposal = try await GitHubReviewThreadPublicationService(modelContext: modelContext)
                        .prepareFirstAvailable(task: task, filePaths: filePaths)
                    return
                } catch {
                    // A file that is still a candidate failed for a transient reason (an
                    // outage, a rate limit). Offering an unrelated review in its place
                    // would swap one GitHub change for another, so show the failure.
                    if GitHubReviewThreadPublicationService.pendingCandidatePath(task: task, filePaths: filePaths) != nil {
                        preparationError = error.localizedDescription
                        return
                    }
                    threadError = error
                }
            }
            do {
                proposal = try await GitHubReviewPublicationService(modelContext: modelContext)
                    .prepareFirstAvailable(task: task, filePaths: filePaths)
            } catch {
                // With no review proposal to fall back on, the thread failure is the
                // useful one to show.
                let hasReview = filePaths.contains(where: GitHubReviewArtifactPolicy.isReviewFile)
                preparationError = (hasReview ? error : (threadError ?? error)).localizedDescription
            }
        }
    }
}

extension View {
    func taskGitHubReviewPublication(
        state: TaskGitHubReviewPublicationState,
        task: AgentTask,
        modelContext: ModelContext,
        onResolved: @escaping () -> Void
    ) -> some View {
        modifier(TaskGitHubReviewPublicationModifier(
            state: state,
            task: task,
            modelContext: modelContext,
            onResolved: onResolved
        ))
    }
}

private struct TaskGitHubReviewPublicationModifier: ViewModifier {
    @Bindable var state: TaskGitHubReviewPublicationState
    let task: AgentTask
    let modelContext: ModelContext
    let onResolved: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.proposal) { proposal in
                GitHubReviewPublicationSheet(
                    proposal: proposal,
                    onPublish: {
                        let receipt = try await GitHubReviewPublicationService(modelContext: modelContext)
                            .publish(task: task, proposal: proposal)
                        state.proposal = nil
                        onResolved()
                        return receipt
                    },
                    onCancel: { state.proposal = nil }
                )
            }
            .sheet(item: $state.threadProposal) { proposal in
                GitHubReviewThreadPublicationSheet(proposal: proposal, onPublish: {
                    let receipt = try await GitHubReviewThreadPublicationService(modelContext: modelContext)
                        .publish(task: task, proposal: proposal)
                    state.threadProposal = nil
                    onResolved()
                    return receipt
                }, onCancel: { state.threadProposal = nil }, onDismiss: {
                    try GitHubReviewThreadPublicationService(modelContext: modelContext).dismiss(task: task, filePath: proposal.filePath)
                    state.threadProposal = nil
                    onResolved()
                })
            }
            .alert("Couldn’t Prepare GitHub Review", isPresented: Binding(
                get: { state.preparationError != nil },
                set: { if !$0 { state.preparationError = nil } }
            )) {
                Button("OK", role: .cancel) { state.preparationError = nil }
            } message: {
                Text(state.preparationError ?? "The review could not be prepared.")
            }
    }
}
