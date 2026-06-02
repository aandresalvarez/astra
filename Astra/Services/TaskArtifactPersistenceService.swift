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
        var seenPaths = Set(task.artifacts.map { normalizedPath($0.path) })
        var created: [Artifact] = []

        for file in files {
            let path = normalizedPath(file.path)
            guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }

            let nextVersion = (task.artifacts
                .filter { normalizedPath($0.path) == path }
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

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.hasPrefix("/") else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
