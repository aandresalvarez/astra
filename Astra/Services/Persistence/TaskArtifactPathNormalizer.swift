import Foundation
import ASTRAModels
import ASTRACore

@MainActor
public enum TaskArtifactPathNormalizer {
    public static func normalizedPath(_ path: String, task: AgentTask) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty or absolute path never reads the roots, and `taskFolder`
        // costs a `fileExists` to answer. Keep that off the common case.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            return normalizedPath(trimmed, workspacePath: "", taskFolder: "")
        }
        let access = TaskWorkspaceAccess(task: task)
        return normalizedPath(
            trimmed,
            workspacePath: access.effectiveWorkspacePath,
            taskFolder: access.taskFolder
        )
    }

    /// The root-carrying form, `nonisolated` so a caller that has already
    /// hoisted the roots on the main actor can normalize a whole artifact list
    /// off it. The task was only ever read for these two strings, and reading
    /// them per path is what made the main-actor version O(artifacts).
    public nonisolated static func normalizedPath(
        _ path: String,
        workspacePath: String,
        taskFolder: String
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }

        let base = workspacePath.isEmpty
            ? URL(fileURLWithPath: taskFolder).deletingLastPathComponent().path
            : workspacePath
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return trimmed
        }
        return URL(fileURLWithPath: base)
            .appendingPathComponent(trimmed)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
