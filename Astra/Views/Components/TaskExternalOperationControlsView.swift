import SwiftData
import SwiftUI
import ASTRAModels

struct TaskExternalOperationActions {
    let poll: @MainActor (UUID) async -> TaskExternalOperationPollResult
    let stopMonitoring: @MainActor (UUID) -> TaskExternalOperationPollResult
    let resumeMonitoring: @MainActor (UUID) -> TaskExternalOperationPollResult
    let cancelExternalWork: @MainActor (UUID) async -> TaskExternalOperationPollResult
    let reactivateQuarantined: @MainActor (UUID) async -> TaskExternalOperationPollResult
}

private struct TaskExternalOperationActionsKey: EnvironmentKey {
    static let defaultValue: TaskExternalOperationActions? = nil
}

extension EnvironmentValues {
    var taskExternalOperationActions: TaskExternalOperationActions? {
        get { self[TaskExternalOperationActionsKey.self] }
        set { self[TaskExternalOperationActionsKey.self] = newValue }
    }
}

extension TaskExternalOperationActions {
    @MainActor
    static func live(runtime: AppRuntimeController) -> Self {
        Self(
            poll: { [runtime] id in
                await runtime.externalOperationMonitor?.poll(operationID: id, trigger: .manual) ?? .missing
            },
            stopMonitoring: { [runtime] id in
                runtime.externalOperationMonitor?.stopMonitoring(operationID: id) ?? .missing
            },
            resumeMonitoring: { [runtime] id in
                runtime.externalOperationMonitor?.resumeMonitoring(operationID: id) ?? .missing
            },
            cancelExternalWork: { [runtime] id in
                await runtime.externalOperationMonitor?.cancelExternalWork(operationID: id) ?? .missing
            },
            reactivateQuarantined: { [runtime] id in
                await runtime.externalOperationMonitor?.reactivateQuarantinedOperation(operationID: id) ?? .missing
            }
        )
    }
}

struct TaskExternalOperationControlsHost: View {
    let taskID: UUID
    @Environment(\.taskExternalOperationActions) private var actions

    var body: some View {
        if let actions {
            TaskExternalOperationControlsView(taskID: taskID, actions: actions)
        }
    }
}

struct TaskExternalOperationControlsView: View {
    private enum PendingConfirmation: Identifiable {
        case stop(UUID)
        case cancel(UUID)
        case reactivate(UUID)

        var id: String {
            switch self {
            case .stop(let id): "stop-\(id.uuidString)"
            case .cancel(let id): "cancel-\(id.uuidString)"
            case .reactivate(let id): "reactivate-\(id.uuidString)"
            }
        }
    }

    @Query private var operations: [TaskExternalOperation]
    private let actions: TaskExternalOperationActions
    @State private var workingOperationID: UUID?
    @State private var statusMessage: String?
    @State private var confirmation: PendingConfirmation?

    init(taskID: UUID, actions: TaskExternalOperationActions) {
        self.actions = actions
        _operations = Query(
            filter: #Predicate<TaskExternalOperation> { $0.taskID == taskID },
            sort: [SortDescriptor(\TaskExternalOperation.createdAt, order: .reverse)]
        )
    }

    private var visibleOperations: [TaskExternalOperation] {
        let actionable = operations.filter { $0.monitoringState != .completed }
        return actionable.isEmpty ? Array(operations.prefix(1)) : Array(actionable.prefix(3))
    }

    var body: some View {
        if !visibleOperations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(Stanford.ui(12, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                    Text("External operation")
                        .font(Stanford.caption(12).weight(.semibold))
                    Spacer()
                    if visibleOperations.count > 1 {
                        Text("\(visibleOperations.count)")
                            .font(Stanford.caption(10).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(visibleOperations) { operation in
                    operationRow(operation)
                    if operation.id != visibleOperations.last?.id {
                        Divider().opacity(0.55)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { confirmation != nil },
                    set: { if !$0 { confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                confirmationButtons
            } message: {
                Text(confirmationMessage)
            }
            .accessibilityIdentifier("TaskExternalOperationControls")
        }
    }

    @ViewBuilder
    private func operationRow(_ operation: TaskExternalOperation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint(for: operation))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(TaskExternalOperationPresentation.executionLabel(operation.executionState))
                        .font(Stanford.caption(12).weight(.semibold))
                    Text("\(TaskExternalOperationPresentation.healthLabel(operation.observationHealth)) · \(backendLabel(operation.backendKindRaw))")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if workingOperationID == operation.id {
                    ProgressView().controlSize(.small)
                }
            }

            if workingOperationID != operation.id {
                actionFooter(operation)
            }
        }
    }

    @ViewBuilder
    private func actionFooter(_ operation: TaskExternalOperation) -> some View {
        HStack(spacing: 12) {
            switch operation.monitoringState {
            case .active:
                Button("Poll now") { runAsync(operation.id, actions.poll) }
                    .accessibilityIdentifier("ExternalOperationPollNow")
                Button("Stop monitoring") { confirmation = .stop(operation.id) }
                    .accessibilityIdentifier("ExternalOperationStopMonitoring")
                Button("Cancel work…", role: .destructive) { confirmation = .cancel(operation.id) }
                    .accessibilityIdentifier("ExternalOperationCancelWork")
            case .stopped:
                Button("Resume monitoring") { apply(actions.resumeMonitoring(operation.id), operationID: operation.id) }
                    .accessibilityIdentifier("ExternalOperationResumeMonitoring")
                if !operation.executionState.isTerminalObservation {
                    Button("Cancel work…", role: .destructive) { confirmation = .cancel(operation.id) }
                }
            case .quarantined:
                Button("Verify and reactivate…") { confirmation = .reactivate(operation.id) }
                    .accessibilityIdentifier("ExternalOperationReactivate")
            case .validating:
                Text("ASTRA is validating process completion.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            case .completed:
                EmptyView()
            }
        }
        .font(Stanford.caption(11).weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(Stanford.lagunita)
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .stop: "Stop monitoring?"
        case .cancel: "Cancel external work?"
        case .reactivate: "Verify and reactivate?"
        case nil: "External operation"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .stop: "ASTRA will stop checking status. The external job will continue running."
        case .cancel: "ASTRA will ask the trusted execution backend to cancel the job. This is separate from stopping monitoring."
        case .reactivate: "ASTRA will verify the local backend ownership record before monitoring resumes. No job will be launched."
        case nil: ""
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch confirmation {
        case .stop(let id):
            Button("Stop monitoring") {
                confirmation = nil
                apply(actions.stopMonitoring(id), operationID: id)
            }
            Button("Keep monitoring", role: .cancel) { confirmation = nil }
        case .cancel(let id):
            Button("Cancel external work", role: .destructive) {
                confirmation = nil
                runAsync(id, actions.cancelExternalWork)
            }
            Button("Keep running", role: .cancel) { confirmation = nil }
        case .reactivate(let id):
            Button("Verify and reactivate") {
                confirmation = nil
                runAsync(id, actions.reactivateQuarantined)
            }
            Button("Leave quarantined", role: .cancel) { confirmation = nil }
        case nil:
            EmptyView()
        }
    }

    private func runAsync(
        _ operationID: UUID,
        _ action: @escaping @MainActor (UUID) async -> TaskExternalOperationPollResult
    ) {
        workingOperationID = operationID
        Task { @MainActor in
            let result = await action(operationID)
            apply(result, operationID: operationID)
        }
    }

    private func apply(_ result: TaskExternalOperationPollResult, operationID: UUID) {
        statusMessage = TaskExternalOperationPresentation.resultMessage(result)
        if workingOperationID == operationID { workingOperationID = nil }
    }

    private func backendLabel(_ kind: String) -> String {
        kind == "docker_workspace_job" ? "Local Docker" : "Managed backend"
    }

    private func tint(for operation: TaskExternalOperation) -> Color {
        if operation.observationHealth == .unreachable || operation.observationHealth == .quarantined {
            return Stanford.poppy
        }
        return switch operation.executionState {
        case .failed, .interrupted, .timedOut: Stanford.failed
        case .processCompleted: Stanford.paloAltoGreen
        case .cancelled: Stanford.coolGrey
        default: Stanford.lagunita
        }
    }
}
