import SwiftUI
import SwiftData
import ASTRAModels

@MainActor
@Observable
final class TaskGitHubReviewPublicationState {
    var proposal: GitHubReviewProposal?
    var preparationError: String?
    private(set) var isPreparing = false

    func prepare(task: AgentTask, filePath: String, modelContext: ModelContext) {
        guard !isPreparing else { return }
        isPreparing = true
        preparationError = nil
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                proposal = try await GitHubReviewPublicationService(modelContext: modelContext)
                    .prepare(task: task, filePath: filePath)
            } catch {
                preparationError = error.localizedDescription
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
