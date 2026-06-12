import Foundation
import SwiftData

struct TaskArtifactReconciliationSummary {
    enum Status: String {
        case unchanged
        case artifactsChanged
        case staleArtifacts
        case duplicateArtifacts
    }

    var discoveredFiles: [TaskOutputDiscoveredFile]
    var createdArtifacts: [Artifact]
    var normalizedArtifacts: [Artifact]
    var normalizedArtifactKinds: [Artifact]
    var duplicateArtifacts: [Artifact]
    var currentArtifacts: [Artifact]
    var staleArtifacts: [Artifact]

    var didChangeArtifactRows: Bool {
        !createdArtifacts.isEmpty || !normalizedArtifacts.isEmpty || !normalizedArtifactKinds.isEmpty
    }

    var status: Status {
        if !duplicateArtifacts.isEmpty {
            return .duplicateArtifacts
        }
        if !staleArtifacts.isEmpty {
            return .staleArtifacts
        }
        if didChangeArtifactRows {
            return .artifactsChanged
        }
        return .unchanged
    }

    var auditFields: [String: String] {
        [
            "result": status.rawValue,
            "discovered_file_count": String(discoveredFiles.count),
            "created_artifact_count": String(createdArtifacts.count),
            "normalized_artifact_count": String(normalizedArtifacts.count),
            "normalized_artifact_kind_count": String(normalizedArtifactKinds.count),
            "duplicate_artifact_count": String(duplicateArtifacts.count),
            "current_artifact_count": String(currentArtifacts.count),
            "stale_artifact_count": String(staleArtifacts.count)
        ]
    }
}

@MainActor
enum TaskArtifactPersistenceService {
    @discardableResult
    static func reconcileTaskOutputArtifacts(
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        fileManager: FileManager = .default
    ) -> TaskArtifactReconciliationSummary {
        reconcileTaskOutputArtifacts(
            TaskOutputDiscovery.files(for: task, fileManager: fileManager),
            for: task,
            modelContext: modelContext,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func reconcileTaskOutputArtifacts(
        _ files: [TaskOutputDiscoveredFile],
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        fileManager: FileManager = .default
    ) -> TaskArtifactReconciliationSummary {
        var normalizedArtifacts: [Artifact] = []
        var normalizedArtifactKinds: [Artifact] = []
        var seenPaths = Set<String>()

        for artifact in task.artifacts {
            let path = normalizedPath(artifact.path, task: task)
            if artifact.path != path {
                artifact.path = path
                normalizedArtifacts.append(artifact)
            }
            let kind = ArtifactKind(rawValue: artifact.type)
            if artifact.type != kind.rawValue {
                artifact.type = kind.rawValue
                normalizedArtifactKinds.append(artifact)
            }
            if !path.isEmpty {
                seenPaths.insert(path)
            }
        }

        var created: [Artifact] = []
        for file in files {
            let path = normalizedPath(file.path, task: task)
            guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }

            let artifact = Artifact(
                task: task,
                type: file.kind.rawValue,
                path: path,
                version: nextVersion(for: path, task: task)
            )
            insertArtifact(artifact, into: task, modelContext: modelContext)
            created.append(artifact)
        }

        let summary = TaskArtifactReconciliationSummary(
            discoveredFiles: files,
            createdArtifacts: created,
            normalizedArtifacts: normalizedArtifacts,
            normalizedArtifactKinds: normalizedArtifactKinds,
            duplicateArtifacts: duplicateArtifacts(for: task),
            currentArtifacts: task.artifacts.filter { artifactExists($0, fileManager: fileManager) },
            staleArtifacts: task.artifacts.filter { !artifactExists($0, fileManager: fileManager) }
        )
        AppLogger.audit(
            .runtimePersistenceSummary,
            category: "Worker",
            taskID: task.id,
            fields: summary.auditFields,
            level: summary.status == .unchanged ? .debug : .info
        )
        return summary
    }

    @discardableResult
    static func persistDiscoveredTaskOutputArtifacts(
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        fileManager: FileManager = .default
    ) -> [Artifact] {
        reconcileTaskOutputArtifacts(for: task, modelContext: modelContext, fileManager: fileManager).createdArtifacts
    }

    @discardableResult
    static func persistDiscoveredTaskOutputArtifacts(
        _ files: [TaskOutputDiscoveredFile],
        for task: AgentTask,
        modelContext: ModelContext? = nil
    ) -> [Artifact] {
        reconcileTaskOutputArtifacts(files, for: task, modelContext: modelContext).createdArtifacts
    }

    @discardableResult
    static func persistFileChangeArtifact(
        _ change: StoredFileChange,
        for task: AgentTask,
        modelContext: ModelContext? = nil
    ) -> Artifact? {
        let path = normalizedPath(change.path, task: task)
        guard !path.isEmpty else { return nil }
        let artifact = Artifact(
            task: task,
            type: artifactKind(for: change).rawValue,
            path: path,
            content: change.content,
            version: nextVersion(for: path, task: task)
        )
        insertArtifact(artifact, into: task, modelContext: modelContext)
        return artifact
    }

    private static func normalizedPath(_ path: String, task: AgentTask) -> String {
        TaskArtifactPathNormalizer.normalizedPath(path, task: task)
    }

    private static func nextVersion(for normalizedPath: String, task: AgentTask) -> Int {
        (task.artifacts
            .filter { Self.normalizedPath($0.path, task: task) == normalizedPath }
            .map(\.version)
            .max() ?? 0) + 1
    }

    private static func insertArtifact(_ artifact: Artifact, into task: AgentTask, modelContext: ModelContext?) {
        modelContext?.insert(artifact)
        if !task.artifacts.contains(where: { $0.id == artifact.id }) {
            task.artifacts.append(artifact)
        }
    }

    private static func duplicateArtifacts(for task: AgentTask) -> [Artifact] {
        let grouped = Dictionary(grouping: task.artifacts) { normalizedPath($0.path, task: task) }
        return grouped.values.flatMap { artifacts -> [Artifact] in
            let sorted = artifacts.sorted {
                if $0.version == $1.version {
                    return $0.createdAt < $1.createdAt
                }
                return $0.version < $1.version
            }
            guard let first = sorted.first,
                  !normalizedPath(first.path, task: task).isEmpty else {
                return []
            }
            return Array(sorted.dropFirst())
        }
    }

    private static func artifactExists(_ artifact: Artifact, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: artifact.path)
    }

    private static func artifactKind(for change: StoredFileChange) -> ArtifactKind {
        let pathKind = ArtifactKind.forPath(change.path)
        guard pathKind != .file else {
            switch change.kind {
            case .write, .edit, .discovered, .unknown:
                return .file
            }
        }
        return pathKind
    }
}
