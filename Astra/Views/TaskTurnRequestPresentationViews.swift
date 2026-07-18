import SwiftUI
import ASTRAModels

/// Quiet, persistent metadata below the exact user bubble that owns a durable
/// turn request. State is communicated in words as well as color so waiting
/// remains understandable with Reduce Motion and VoiceOver.
struct TaskTurnMessageLifecycleChip: View {
    let presentation: TaskTurnMessageLifecyclePresentation

    private var tint: Color {
        switch presentation.state {
        case .waitingForWorker, .waitingForResource, .admitted: Stanford.poppy
        case .running: Stanford.lagunita
        case .completed: Stanford.completed
        case .failed: Stanford.failed
        case .cancelled: Stanford.coolGrey
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.systemImage)
                .font(Stanford.ui(9, weight: .semibold))
            Text(presentation.title)
                .font(Stanford.caption(10).weight(.medium))
            if let detail = presentation.detail, !detail.isEmpty {
                Text("· \(detail)")
                    .font(Stanford.caption(10))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10))
        .clipShape(Capsule())
        .accessibilityLabel(presentation.accessibilityLabel)
        .help(presentation.accessibilityLabel)
    }
}

extension TaskMainView {
    /// This relationship intentionally stays one-way in SwiftData for the
    /// additive V15 migration. Fetch through the repository instead of adding
    /// a persisted inverse to `AgentTask`.
    var taskTurnRequestSnapshots: [TaskTurnRequestSnapshot] {
        (try? TaskTurnRequestRepository.requests(for: task, in: modelContext))?
            .compactMap(\.snapshot) ?? []
    }

    var taskActivityPresentation: TaskActivityPresentation {
        TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: taskTurnRequestSnapshots
        )
    }

    var taskTurnWaitingDockPresentation: TaskDecisionDockPresentation? {
        guard let title = taskActivityPresentation.dockTitle,
              let summary = taskActivityPresentation.dockSummary else {
            return nil
        }
        return TaskDecisionDockPresentation(
            id: "turn-request-\(taskActivityPresentation.request?.id.uuidString ?? task.id.uuidString)",
            icon: taskActivityPresentation.sidebarSystemImage ?? "clock",
            tone: .attention,
            title: title,
            summary: summary,
            metrics: [],
            details: [],
            primaryAction: nil,
            secondaryActions: [],
            overflowActions: [],
            prefersExpandedDetails: false
        )
    }
}
