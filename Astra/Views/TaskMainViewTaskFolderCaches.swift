import Foundation
import SwiftUI
import ASTRAModels
import ASTRAPersistence

/// Caches of what is in the task folder, kept off `TaskMainView.body`.
///
/// `body` reads `messageText`, so it re-runs on every keystroke, and both of
/// these used to touch the folder from it: the diagnostics key named the task
/// folder, which is a `stat` to resolve (and counted `task.artifacts`, a
/// relationship fault), and every run bubble classified its changed paths
/// with symlink walks. Same shape as `recomputeHeaderFileItems`: a key of
/// values the view already holds gates a `.task(id:)`, and the folder is
/// resolved and read off the main actor, in loaders cancelled with it.
extension TaskMainView {
    // MARK: Diagnostics

    /// Coarse on purpose. Diagnostics land as a run progresses and finishes,
    /// which moves the run and event counts or the latest run; files a run
    /// generates move `generatedFilesRevision`, bumped by the same callback
    /// that refreshes the generated-files list.
    var diagnosticFileGroupsInputSignature: String {
        let snapshot = threadViewModel.snapshot
        let latestRun = snapshot?.latestRun
        return [
            task.id.uuidString,
            task.status.rawValue,
            TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            "\(snapshot?.totalRunCount ?? 0)",
            "\(snapshot?.totalEventCount ?? 0)",
            latestRun?.id.uuidString ?? "none",
            latestRun?.status.rawValue ?? "none",
            "\(latestRun?.fileChangesJSONLength ?? 0)",
            "\(generatedFilesRevision)"
        ].joined(separator: "|")
    }

    func recomputeDiagnosticFileGroups() async {
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id
        // Off the main actor, and cancelled with this `.task(id:)`.
        let groups = await TaskDiagnosticsIndex.groups(workspacePath: workspacePath, taskID: taskID)
        guard let groups, !Task.isCancelled else { return }
        diagnosticFileGroupsCache = groups
    }

    // MARK: Changed-file counts

    var runFileChangeCountInputs: TaskRunVisibleFileChangeCounts.Inputs {
        TaskRunVisibleFileChangeCounts.Inputs(
            taskID: task.id,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            folderRevision: taskFolderRevision,
            runs: (threadViewModel.snapshot?.sortedRuns ?? []).map {
                TaskRunVisibleFileChangeCounts.Run(id: $0.id, fileChangesJSONLength: $0.fileChangesJSONLength)
            }
        )
    }

    /// Zero until the first count lands; the footer shows its button once it does.
    func visibleFileChangeCount(for run: TaskRunSnapshot) -> Int {
        runFileChangeCountsCache.count(for: run.id) ?? 0
    }

    func recomputeRunFileChangeCounts() async {
        let inputs = runFileChangeCountInputs
        let needed = runFileChangeCountsCache.runsNeedingCount(inputs)
        guard !needed.isEmpty else {
            // Nothing to count, but runs may have left the snapshot; drop
            // their entries. Compared first so an unchanged cache is not
            // written back, which would redraw `body` for nothing.
            let pruned = runFileChangeCountsCache.merging([:], for: inputs)
            if pruned != runFileChangeCountsCache { runFileChangeCountsCache = pruned }
            return
        }
        // The paths are already decoded in the snapshot; take them here, where
        // it is safe to read, and hand the loader plain strings.
        let pending = (threadViewModel.snapshot?.sortedRuns ?? []).filter { needed.contains($0.id) }.map {
            TaskRunVisibleFileChangeCounts.Pending(
                id: $0.id,
                fileChangesJSONLength: $0.fileChangesJSONLength,
                paths: $0.fileChanges.map(\.path)
            )
        }
        // Off the main actor, and cancelled with this `.task(id:)`.
        let counted = await TaskRunVisibleFileChangeCounts.counted(
            pending,
            workspacePath: inputs.workspacePath,
            taskID: inputs.taskID
        )
        // Under `.task(id:)`: don't apply a result whose inputs are now stale.
        guard let counted, !Task.isCancelled else { return }
        // A legacy folder can migrate while this counted, or since the counts
        // it would join were taken, and nothing in the key moves with it.
        // Either way every run is recounted under a new revision. One `stat`
        // per rebuild, not per keystroke; it converges, since both sides
        // resolve the folder the same way and a new revision keeps nothing.
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard counted.taskFolder == folder,
              runFileChangeCountsCache.canMerge(countedIn: folder, for: inputs) else {
            taskFolderRevision &+= 1
            return
        }
        runFileChangeCountsCache = runFileChangeCountsCache.merging(counted.entries, for: inputs, countedIn: folder)
    }

    /// After the view's own context refresh; `folder` is the task folder as it
    /// resolves now. Counts judged against another folder are recounted, which
    /// holds whatever did the migrating, even a refresh that was cancelled
    /// before it could say so.
    func noteContextRefreshForFileChangeCounts(folder: String) {
        guard runFileChangeCountsCache.isStale(forFolder: folder) else { return }
        taskFolderRevision &+= 1
    }
}
