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
    /// Turn requests reference their task by a scalar `taskID` (no SwiftData
    /// relationship / synthesized inverse) so V15 stays an additive migration.
    /// Fetch through the repository rather than adding a persisted inverse to
    /// `AgentTask`.
    /// Activity state only ever derives from active requests, so the dock and
    /// composer paths must not pay for the append-only table's full history.
    var taskActiveTurnRequestSnapshots: [TaskTurnRequestSnapshot] {
        (try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext))?
            .map(\.snapshot) ?? []
    }

    /// Message-chip source, bounded to active requests plus the requests whose
    /// user bubbles are inside the visible transcript window.
    func turnRequestSnapshots(visibleMessageEventIDs: [UUID]) -> [TaskTurnRequestSnapshot] {
        (try? TaskTurnRequestRepository.presentationRequests(
            for: task,
            visibleMessageEventIDs: visibleMessageEventIDs,
            in: modelContext
        ))?.map(\.snapshot) ?? []
    }

    var taskActivityPresentation: TaskActivityPresentation {
        TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: taskActiveTurnRequestSnapshots
        )
    }

    var taskTurnWaitingDockPresentation: TaskDecisionDockPresentation? {
        guard let title = taskActivityPresentation.dockTitle,
              let summary = taskActivityPresentation.dockSummary else {
            return nil
        }
        // While the turn waits, the task keeps its previous status, so the
        // status-gated Cancel surfaces are unavailable and the composer's stop
        // callback is suppressed by this dock. The dock itself must therefore
        // offer the one way to retract a saved turn before it runs — scoped to
        // this request, not `.stop`, so cancelling a queued follow-up never
        // flips the task's own terminal status.
        let dockRequest = taskActivityPresentation.dockRequest
        let cancelAction: TaskDecisionDockAction? = {
            guard taskQueue != nil,
                  let requestID = dockRequest?.id else { return nil }
            return TaskDecisionDockAction(
                kind: .cancelTurnRequest,
                title: taskActivityPresentation.kind == .running ? "Cancel queued message" : "Cancel request",
                systemImage: "xmark.circle",
                payload: requestID.uuidString,
                help: "Cancel this saved message before it runs."
            )
        }()
        // A queued follow-up behind a running run also shows this dock, and
        // any visible dock suppresses the composer's stop control — so the
        // whole-run stop must ride along here or it becomes unreachable.
        let stopAction: TaskDecisionDockAction? = {
            guard taskActivityPresentation.kind == .running, onCancelTask != nil else { return nil }
            return TaskDecisionDockAction(
                kind: .stop,
                title: "Stop run",
                systemImage: "stop.circle",
                help: "Stop the active run. Queued messages stay saved."
            )
        }()
        return TaskDecisionDockPresentation(
            id: "turn-request-\(dockRequest?.id.uuidString ?? task.id.uuidString)",
            icon: taskActivityPresentation.sidebarSystemImage ?? "clock",
            tone: taskActivityPresentation.kind == .running ? .running : .attention,
            title: title,
            summary: summary,
            metrics: [],
            details: [],
            primaryAction: nil,
            secondaryActions: [cancelAction, stopAction].compactMap { $0 },
            overflowActions: [],
            prefersExpandedDetails: false
        )
    }
}
