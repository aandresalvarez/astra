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
    /// The pending record `prepare` failed on, kept so the failure has an exit.
    ///
    /// `prepare` cannot build a `ConnectorMutationProposal` when it fails, and
    /// without something identifying the row there is nothing to retire — which
    /// is how this state used to become permanent.
    private(set) var unreadable: TaskStagedConnectorMutation?
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
        unreadable = nil
        defer { isPreparing = false }
        do {
            proposal = try ConnectorMutationCoordinator(modelContext: modelContext)
                .prepare(task: task, pending: pending)
        } catch {
            proposal = nil
            preparationError = error.localizedDescription
            unreadable = pending
        }
    }

    /// Retires the proposal `prepare` could not open.
    ///
    /// The dock reads pending proposals from the event log, so dismissing the
    /// alert alone changed nothing: the row came straight back, and it sorts
    /// above the correction and advisory rows, so it hid the actions the user
    /// could still take. Recording the quarantine is what actually clears it.
    func quarantine(task: AgentTask, modelContext: ModelContext, onResolved: () -> Void) {
        guard let pending = unreadable, let reason = preparationError else { return }
        do {
            try ConnectorMutationCoordinator(modelContext: modelContext)
                .quarantine(task: task, pending: pending, reason: reason)
            unreadable = nil
            preparationError = nil
            onResolved()
        } catch {
            // The store refused the retirement, so the row is still pending and
            // saying otherwise would be a lie. Replacing the message keeps the
            // alert up with the reason it did not work.
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
                // Destructive, and not the default. Retiring the proposal is
                // the only way out of this state, but it is still discarding
                // something the agent composed — so the user leaves through it
                // deliberately rather than by pressing return.
                Button("Discard Proposal", role: .destructive) {
                    state.quarantine(task: task, modelContext: modelContext, onResolved: onResolved)
                }
                Button("Keep Pending", role: .cancel) { state.preparationError = nil }
            } message: {
                Text(
                    (state.preparationError ?? "The staged payload could not be read.")
                        + "\n\nDiscarding stops ASTRA offering this proposal for review. "
                        + "The staged file is left in the task folder."
                )
            }
    }
}
