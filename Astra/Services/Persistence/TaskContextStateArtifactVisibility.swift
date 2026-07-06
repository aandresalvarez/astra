import Foundation
import ASTRAModels

extension TaskContextStateManager {
    @MainActor
    static func isUserFacingOutputPath(
        _ path: String,
        task: AgentTask,
        access: TaskWorkspaceAccess
    ) -> Bool {
        let normalizedPath = TaskArtifactPathNormalizer.normalizedPath(path, task: task)
        guard !normalizedPath.isEmpty else { return false }

        if let relative = TaskOutputArtifactPathPolicy.relativePath(normalizedPath, under: access.taskFolder) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }

        if let relative = TaskOutputArtifactPathPolicy.relativePath(normalizedPath, under: access.effectiveWorkspacePath) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .workspace
            ) != nil
        }

        return true
    }
}
