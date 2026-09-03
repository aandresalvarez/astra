import Foundation
import SwiftUI
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Keeps `TaskMainView.decisionArtifactPathsCache` current.
///
/// The list this produces used to be a plain computed property feeding
/// `taskDecisionDockPresentation`, which `body` evaluates on every pass — so it
/// re-ran on every keystroke in the composer, at O(artifacts) syscalls a time.
/// `TaskDecisionArtifactPathFilter` has the full account of the cost.
///
/// It follows the same shape as `recomputeHeaderFileItems`: a syscall-free
/// signature gates a `.task(id:)`, the roots are hoisted on the main actor, and
/// the walk itself happens in a detached task.
extension TaskMainView {
    /// Cheap, syscall-free signature for the decision dock's artifact list.
    ///
    /// Deliberately coarse. Reading `task.artifacts` here would fault the whole
    /// relationship on every keystroke, and avoiding exactly that is most of
    /// the point — so this leans on the fact that artifacts are reconciled at
    /// run finalize, which moves run identity and status with them.
    var decisionArtifactPathsInputSignature: String {
        let snapshot = threadViewModel.snapshot
        let latestRun = snapshot?.latestRun
        return [
            task.status.rawValue,
            "\(snapshot?.totalRunCount ?? 0)",
            latestRun?.id.uuidString ?? "none",
            latestRun?.status.rawValue ?? "none",
            threadViewModel.generatedFilePaths.joined(separator: ",")
        ].joined(separator: "|")
    }

    func recomputeDecisionArtifactPaths() async {
        let generatedFilePaths = threadViewModel.generatedFilePaths
        // Mapped on the main actor: a SwiftData relationship cannot be read
        // from the detached task below, and `\.path` is all the filter needs.
        let storedArtifactPaths = task.artifacts.map(\.path)
        let access = TaskWorkspaceAccess(task: task)
        let roots = TaskDecisionArtifactPathFilter.Roots(
            workspacePath: access.effectiveWorkspacePath,
            taskFolder: access.taskFolder
        )
        let paths = await Task.detached(priority: .userInitiated) {
            TaskDecisionDockContextBuilder.artifactPaths(
                generatedFilePaths: generatedFilePaths,
                storedArtifactPaths: TaskDecisionArtifactPathFilter.userFacingPaths(
                    storedArtifactPaths: storedArtifactPaths,
                    roots: roots
                )
            )
        }.value
        // Under `.task(id:)`: don't apply a result whose inputs are now stale.
        guard !Task.isCancelled else { return }
        decisionArtifactPathsCache = paths
    }
}
