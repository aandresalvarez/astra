import Foundation
import SwiftUI
import ASTRAModels
import ASTRAPersistence

/// Keeps `TaskMainView.missionControlSnapshotCache` current.
///
/// The snapshot used to be a computed property that `body` reached two or
/// three times per pass, and every pass — every keystroke in the composer —
/// read and decoded `current_state.json` on the main thread each time.
/// `TaskMissionControlSnapshot` has the full account.
///
/// Same shape as `recomputeHeaderFileItems`: a syscall-free key gates a
/// `.task(id:)`, and the disk read happens off the main actor, here in a
/// cancellable `nonisolated async` loader. What is different is the
/// invalidation. The key cannot see the file, so `missionControlStateRevision`
/// stands in for it, bumped by `TaskContextStateSaveObserver` on each save and
/// by `noteContextRefreshForMissionControl()` when the folder moved without one.
extension TaskMainView {
    var missionControlSnapshotInputs: TaskMissionControlSnapshot.Inputs {
        TaskMissionControlSnapshot.Inputs(
            task: task,
            thread: threadViewModel.snapshot,
            planState: currentPlanState,
            stateRevision: missionControlStateRevision
        )
    }

    var missionControlPresentation: MissionControlPresentation? {
        guard missionControlSnapshotCache.taskID == task.id else { return nil }
        return missionControlSnapshotCache.presentation
    }

    var verificationLoadRequest: TaskVerificationLoadRequest? {
        guard missionControlSnapshotCache.taskID == task.id else { return nil }
        return TaskMissionControlSnapshot.verificationLoadRequest(
            task: task,
            taskFolder: missionControlSnapshotCache.taskFolder,
            isFinished: isFinished
        )
    }

    func recomputeMissionControlSnapshot() async {
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id
        // Off the main actor, and cancelled with this `.task(id:)`: a rebuild
        // superseded before its read began skips the read altogether.
        let source = await TaskMissionControlSnapshot.Source.loaded(workspacePath: workspacePath, taskID: taskID)
        // Under `.task(id:)`: don't apply a result whose inputs are now stale.
        // `build` reads the model, so a task deleted while the file loaded is
        // left alone too — and a persisted deletion can leave the model
        // detached with `isDeleted` still false, hence the context check.
        guard let source, !Task.isCancelled, !task.isDeleted, task.modelContext != nil else { return }
        missionControlSnapshotCache = TaskMissionControlSnapshot.build(
            task: task,
            planState: currentPlanState,
            source: source
        )
    }

    /// After the view's own context refresh; `folderBefore` is the folder as
    /// it resolved just before it. See
    /// `TaskMissionControlSnapshot.contextRefreshLeftSnapshotStale`.
    func noteContextRefreshForMissionControl(announcedSave: Bool, folderBefore: String) {
        guard TaskMissionControlSnapshot.contextRefreshLeftSnapshotStale(
            announcedSave: announcedSave,
            folderBefore: folderBefore,
            folderAfter: TaskWorkspaceAccess(task: task).taskFolder
        ) else { return }
        missionControlStateRevision &+= 1
    }
}

/// Rebuilds the snapshot when its key moves, and moves the key when this
/// task's `current_state.json` is saved.
///
/// A modifier rather than two more entries on `TaskMainView.body`'s modifier
/// chain: the chain is a single expression, and with these two closures
/// inline, CI's compiler gave up on type-checking it in reasonable time. Here
/// the chain pays for one call that takes values and a method reference.
struct TaskMissionControlSnapshotRefresh: ViewModifier {
    let inputs: TaskMissionControlSnapshot.Inputs
    @Binding var stateRevision: Int
    let recompute: () async -> Void

    func body(content: Content) -> some View {
        content
            .task(id: inputs) {
                await recompute()
            }
            .background {
                TaskContextStateSaveObserver(taskID: inputs.taskID) {
                    stateRevision &+= 1
                }
            }
    }
}
