import SwiftUI
import ASTRAModels

/// Invalidation observers for `TaskMainView`. Each renders `Color.clear` and
/// exists only to translate a durable change signal into a view-side refresh,
/// so the main view keeps its refresh triggers narrow and explicit.

/// Thread refresh is revision/event driven. `AgentTask.updatedAt` covers durable
/// lifecycle and ordinary event mutations; `taskThreadDidChange` covers coalesced streaming mutations.
struct TaskThreadChangeObserver: View {
    let task: AgentTask
    let generatedFilesLatestRun: TaskRunSnapshot?
    let onSnapshotChange: () -> Void
    let onGeneratedFilesChange: () -> Void
    var body: some View {
        Color.clear
            .onChange(of: task.updatedAt) { _, _ in
                onSnapshotChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .taskThreadDidChange)) { notification in
                guard let change = notification.object as? TaskThreadChange,
                      change.taskID == task.id else { return }
                onSnapshotChange()
            }
            .onChange(of: TaskGeneratedFilesTrigger(task: task, latestRun: generatedFilesLatestRun)) { _, _ in
                onGeneratedFilesChange()
            }
    }
}

/// Bumps a counter only when a durable plan-relevant event lands for this task.
/// Drives `planStateCacheRefreshTrigger` so the plan projection is re-read when
/// it can actually have changed instead of on every `task.updatedAt` bump.
struct TaskPlanEventObserver: View {
    let task: AgentTask
    let onPlanEvent: () -> Void
    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .durableTaskEventInserted)) { notification in
                guard let insertion = notification.object as? DurableTaskEventInsertion,
                      insertion.taskID == task.id,
                      TaskPlanEventRelevance.affectsPlanState(eventType: insertion.type) else { return }
                onPlanEvent()
            }
    }
}
