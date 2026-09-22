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
/// `.task(id:)`, and the disk read happens in a detached task. What is
/// different is the invalidation. The key cannot see the file, so
/// `missionControlStateRevision` stands in for it, bumped by
/// `TaskContextStateSaveObserver` on each save and after the view's own
/// context refresh.
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
        let source = await Task.detached(priority: .userInitiated) {
            TaskMissionControlSnapshot.Source.load(workspacePath: workspacePath, taskID: taskID)
        }.value
        // Under `.task(id:)`: don't apply a result whose inputs are now stale.
        // `build` reads the model, so a task deleted while the file loaded is
        // left alone too.
        guard !Task.isCancelled, !task.isDeleted else { return }
        missionControlSnapshotCache = TaskMissionControlSnapshot.build(
            task: task,
            planState: currentPlanState,
            source: source
        )
    }
}
