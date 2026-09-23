import SwiftUI
import ASTRAModels
import ASTRAPersistence

/// Invalidation observers for `TaskMainView`. Each renders `Color.clear` and
/// exists only to translate a durable change signal into a view-side refresh,
/// so the main view keeps its refresh triggers narrow and explicit.

/// Thread refresh is revision/event driven. `AgentTask.updatedAt` covers durable
/// lifecycle and ordinary event mutations; `taskThreadDidChange` covers coalesced streaming mutations.
/// Generated files hear about new artifact rows through `taskArtifactsDidChange`
/// rather than a per-pass count; see `TaskGeneratedFilesTrigger`.
struct TaskThreadChangeObserver: View {
    let task: AgentTask
    let generatedFilesLatestRun: TaskRunSnapshot?
    let onSnapshotChange: () -> Void
    let onGeneratedFilesChange: () -> Void
    /// A counter, not a direct call, so that rows added in one burst still
    /// reach `onGeneratedFilesChange` once per update, as the count used to.
    @State private var artifactsRevision = 0

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
            .onReceive(NotificationCenter.default.publisher(for: .taskArtifactsDidChange)) { notification in
                guard let change = notification.object as? TaskArtifactsChange,
                      change.taskID == task.id else { return }
                artifactsRevision &+= 1
            }
            .onChange(of: TaskGeneratedFilesTrigger(
                task: task,
                latestRun: generatedFilesLatestRun,
                artifactsRevision: artifactsRevision
            )) { _, _ in
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

/// Bumps a counter when this task's `current_state.json` is written. Drives
/// `missionControlSnapshotInputs`, whose other inputs cannot see the file; see
/// `TaskContextStateSave` for why nothing else moves with it. Received on the
/// main run loop because `saveState` is not actor-isolated.
struct TaskContextStateSaveObserver: View {
    let taskID: UUID
    let onSave: () -> Void
    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .taskContextStateDidSave).receive(on: RunLoop.main)) { notification in
                guard let save = notification.object as? TaskContextStateSave,
                      save.taskID == taskID else { return }
                onSave()
            }
    }
}
