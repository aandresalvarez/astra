import Foundation
import ASTRAModels
import ASTRACore

/// The two roots `isUserFacingOutputPath` classifies against, resolved once.
///
/// The filter runs over every recorded file change and every discovered output
/// for a task, and each call used to resolve both roots from scratch. On a task
/// folder an agent had filled with a 14,917-file virtualenv that was enough to
/// pin the main thread indefinitely: `updateDerivedFields` re-fires on every
/// task update, so each pass restarted before the previous one could finish and
/// the app never came back.
public struct TaskOutputVisibilityScope {
    public let taskFolder: TaskOutputArtifactPathPolicy.ResolvedRoot
    public let workspace: TaskOutputArtifactPathPolicy.ResolvedRoot

    @MainActor
    public init(access: TaskWorkspaceAccess) {
        self.init(
            taskFolder: access.taskFolder,
            workspacePath: access.effectiveWorkspacePath
        )
    }

    public init(taskFolder: String, workspacePath: String) {
        self.taskFolder = .init(taskFolder)
        self.workspace = .init(workspacePath)
    }
}

extension TaskContextStateManager {
    @MainActor
    public static func isUserFacingOutputPath(
        _ path: String,
        task: AgentTask,
        access: TaskWorkspaceAccess
    ) -> Bool {
        isUserFacingOutputPath(path, task: task, scope: TaskOutputVisibilityScope(access: access))
    }

    @MainActor
    public static func isUserFacingOutputPath(
        _ path: String,
        task: AgentTask,
        scope: TaskOutputVisibilityScope
    ) -> Bool {
        let normalizedPath = TaskArtifactPathNormalizer.normalizedPath(path, task: task)
        guard !normalizedPath.isEmpty else { return false }

        // Settle the generated-dependency case lexically, before any symlink
        // resolution. A `.venv` or `node_modules` tree holds tens of thousands
        // of files and not one of them is an output, so paying a
        // `resolvingSymlinksInPath()` per entry only to discard it is the
        // entire cost of the pass. Judged on the path *relative to a root* so
        // that a workspace which itself lives under a directory called `venv`
        // does not disappear wholesale.
        if let lexical = TaskOutputArtifactPathPolicy.lexicalRelativePath(normalizedPath, under: scope.taskFolder)
            ?? TaskOutputArtifactPathPolicy.lexicalRelativePath(normalizedPath, under: scope.workspace),
           TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent(lexical) {
            return false
        }

        if let relative = TaskOutputArtifactPathPolicy.relativePath(normalizedPath, under: scope.taskFolder) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }

        if let relative = TaskOutputArtifactPathPolicy.relativePath(normalizedPath, under: scope.workspace) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .workspace
            ) != nil
        }

        return true
    }
}
