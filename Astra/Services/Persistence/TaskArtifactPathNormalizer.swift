import Foundation
import ASTRAModels
import ASTRACore

@MainActor
public enum TaskArtifactPathNormalizer {
    public static func normalizedPath(_ path: String, task: AgentTask) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }

        let access = TaskWorkspaceAccess(task: task)
        let base = access.effectiveWorkspacePath.isEmpty
            ? URL(fileURLWithPath: access.taskFolder).deletingLastPathComponent().path
            : access.effectiveWorkspacePath
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
