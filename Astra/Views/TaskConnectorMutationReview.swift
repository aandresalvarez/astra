import SwiftUI
import SwiftData
import ASTRAModels

/// The connector-mutation review, packaged so `TaskMainView` carries the wiring
/// and not the flow.
///
/// A focused boundary rather than four more members on a 6,000-line view: the
/// state, the preparation, and the sheet belong together, and the detail view
/// only needs to know that a review can be opened. It also keeps this reviewable
/// on its own, which for the one surface in the app that authorises an outbound
/// write is worth more than the convenience of inlining it.
@MainActor
@Observable
final class TaskConnectorMutationReviewState {
    var proposal: ConnectorMutationProposal?
    var preparationError: String?
    private(set) var isPreparing = false

    /// Destinations of everything still awaiting review, for the dock row.
    static func pendingTargets(task: AgentTask) -> [String] {
        ConnectorMutationRequirementResolver.pendingMutations(task: task).map(\.target)
    }

    /// Reads the oldest pending proposal back off disk and opens the sheet.
    ///
    /// Opens on the oldest rather than the newest so the user works through them
    /// in the order the agent composed them — a later proposal may depend on an
    /// earlier one having been filed.
    func prepare(task: AgentTask, modelContext: ModelContext) {
        guard !isPreparing else { return }
        guard let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task).first else {
            return
        }
        isPreparing = true
        preparationError = nil
        defer { isPreparing = false }
        do {
            proposal = try ConnectorMutationCoordinator(modelContext: modelContext)
                .prepare(task: task, pending: pending)
        } catch {
            proposal = nil
            preparationError = error.localizedDescription
        }
    }
}

extension View {
    /// Installs the review sheet and its failure alert.
    func taskConnectorMutationReview(
        state: TaskConnectorMutationReviewState,
        task: AgentTask,
        modelContext: ModelContext,
        onResolved: @escaping () -> Void
    ) -> some View {
        modifier(TaskConnectorMutationReviewModifier(
            state: state,
            task: task,
            modelContext: modelContext,
            onResolved: onResolved
        ))
    }
}

private struct TaskConnectorMutationReviewModifier: ViewModifier {
    @Bindable var state: TaskConnectorMutationReviewState
    let task: AgentTask
    let modelContext: ModelContext
    let onResolved: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.proposal) { proposal in
                ConnectorMutationReviewSheet(
                    proposal: proposal,
                    onSend: {
                        let receipt = try await ConnectorMutationCoordinator(modelContext: modelContext)
                            .send(task: task, proposal: proposal)
                        state.proposal = nil
                        onResolved()
                        return receipt
                    },
                    onDecline: {
                        try ConnectorMutationCoordinator(modelContext: modelContext)
                            .decline(task: task, proposal: proposal)
                        state.proposal = nil
                        onResolved()
                    },
                    onCancel: { state.proposal = nil }
                )
            }
            .alert("Couldn’t Open This Proposal", isPresented: Binding(
                get: { state.preparationError != nil },
                set: { if !$0 { state.preparationError = nil } }
            )) {
                Button("OK", role: .cancel) { state.preparationError = nil }
            } message: {
                Text(state.preparationError ?? "The staged payload could not be read.")
            }
    }
}
