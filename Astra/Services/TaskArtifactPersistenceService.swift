import Foundation
import SwiftData

@MainActor
enum TaskArtifactPersistenceService {
    @discardableResult
    static func persistDiscoveredTaskOutputArtifacts(
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        fileManager: FileManager = .default
    ) -> [Artifact] {
        persistDiscoveredTaskOutputArtifacts(
            TaskOutputDiscovery.files(for: task, fileManager: fileManager),
            for: task,
            modelContext: modelContext
        )
    }

    @discardableResult
    static func persistDiscoveredTaskOutputArtifacts(
        _ files: [TaskOutputDiscoveredFile],
        for task: AgentTask,
        modelContext: ModelContext? = nil
    ) -> [Artifact] {
        var seenPaths = Set<String>()
        for artifact in task.artifacts {
            let path = normalizedPath(artifact.path, task: task)
            if artifact.path != path {
                artifact.path = path
            }
            if !path.isEmpty {
                seenPaths.insert(path)
            }
        }
        var created: [Artifact] = []

        for file in files {
            let path = normalizedPath(file.path, task: task)
            guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }

            let nextVersion = (task.artifacts
                .filter { normalizedPath($0.path, task: task) == path }
                .map(\.version)
                .max() ?? 0) + 1
            let artifact = Artifact(
                task: task,
                type: file.type,
                path: path,
                version: nextVersion
            )
            modelContext?.insert(artifact)
            if !task.artifacts.contains(where: { $0.id == artifact.id }) {
                task.artifacts.append(artifact)
            }
            created.append(artifact)
        }

        return created
    }

    private static func normalizedPath(_ path: String, task: AgentTask) -> String {
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
