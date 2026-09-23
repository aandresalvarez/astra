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
/// resolved and read in a detached task.
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
        let groups = await Task.detached(priority: .utility) {
            TaskDiagnosticsIndex.groups(
                in: TaskFolderResolvingAdapter.taskFolder(workspacePath: workspacePath, taskID: taskID)
            )
        }.value
        guard !Task.isCancelled else { return }
        diagnosticFileGroupsCache = groups
    }

    // MARK: Changed-file counts

    var runFileChangeCountInputs: TaskRunVisibleFileChangeCounts.Inputs {
        TaskRunVisibleFileChangeCounts.Inputs(
            taskID: task.id,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
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
        guard !needed.isEmpty else { return }
        // The paths are already decoded in the snapshot; take them here, where
        // it is safe to read, and hand the detached task plain strings.
        let pending = (threadViewModel.snapshot?.sortedRuns ?? []).filter { needed.contains($0.id) }.map {
            TaskRunVisibleFileChangeCounts.Pending(
                id: $0.id,
                fileChangesJSONLength: $0.fileChangesJSONLength,
                paths: $0.fileChanges.map(\.path)
            )
        }
        let counted = await Task.detached(priority: .userInitiated) {
            TaskRunVisibleFileChangeCounts.counted(
                pending,
                taskFolder: TaskFolderResolvingAdapter.taskFolder(workspacePath: inputs.workspacePath, taskID: inputs.taskID)
            )
        }.value
        // Under `.task(id:)`: don't apply a result whose inputs are now stale.
        guard !Task.isCancelled else { return }
        runFileChangeCountsCache = runFileChangeCountsCache.merging(counted, for: inputs)
    }
}
