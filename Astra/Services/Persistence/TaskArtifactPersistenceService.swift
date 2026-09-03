import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

public struct TaskArtifactReconciliationSummary {
    public init(discoveredFiles: [TaskOutputDiscoveredFile], createdArtifacts: [Artifact], normalizedArtifacts: [Artifact], normalizedArtifactKinds: [Artifact], duplicateArtifacts: [Artifact], currentArtifacts: [Artifact], staleArtifacts: [Artifact]) {
        self.discoveredFiles = discoveredFiles
        self.createdArtifacts = createdArtifacts
        self.normalizedArtifacts = normalizedArtifacts
        self.normalizedArtifactKinds = normalizedArtifactKinds
        self.duplicateArtifacts = duplicateArtifacts
        self.currentArtifacts = currentArtifacts
        self.staleArtifacts = staleArtifacts
    }

    public enum Status: String {
        case unchanged
        case artifactsChanged
        case staleArtifacts
        case duplicateArtifacts
    }

    public var discoveredFiles: [TaskOutputDiscoveredFile]
    public var createdArtifacts: [Artifact]
    public var normalizedArtifacts: [Artifact]
    public var normalizedArtifactKinds: [Artifact]
    public var duplicateArtifacts: [Artifact]
    public var currentArtifacts: [Artifact]
    public var staleArtifacts: [Artifact]

    public var didChangeArtifactRows: Bool {
        !createdArtifacts.isEmpty || !normalizedArtifacts.isEmpty || !normalizedArtifactKinds.isEmpty
    }

    public var status: Status {
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

    public var auditFields: [String: String] {
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
public enum TaskArtifactPersistenceService {
    @discardableResult
    public static func reconcileTaskOutputArtifacts(
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
    public static func reconcileTaskOutputArtifacts(
        _ files: [TaskOutputDiscoveredFile],
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        fileManager: FileManager = .default
    ) -> TaskArtifactReconciliationSummary {
        var normalizedArtifacts: [Artifact] = []
        var normalizedArtifactKinds: [Artifact] = []
        var seenPaths = Set<String>()
        // Everything the loops below need about the rows already on the task,
        // gathered in the single pass that was walking them anyway.
        //
        // This used to be four more passes: `nextVersion` and
        // `insertArtifact` each scanned `task.artifacts` from scratch *per
        // created file*, and `duplicateArtifacts` re-normalised every path a
        // second time. At 13,295 artifacts — an agent's virtualenv, before
        // `generatedDependencyDirectoryNames` started excluding those — that is
        // where run finalization's ten seconds went.
        var highestVersionByPath: [String: Int] = [:]
        var heldArtifactIDs = Set<UUID>()
        var artifactsByNormalizedPath: [String: [Artifact]] = [:]

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
            heldArtifactIDs.insert(artifact.id)
            artifactsByNormalizedPath[path, default: []].append(artifact)
            if !path.isEmpty {
                seenPaths.insert(path)
                highestVersionByPath[path] = max(highestVersionByPath[path] ?? 0, artifact.version)
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
                version: (highestVersionByPath[path] ?? 0) + 1
            )
            insertArtifact(
                artifact,
                into: task,
                modelContext: modelContext,
                heldArtifactIDs: &heldArtifactIDs
            )
            created.append(artifact)
            highestVersionByPath[path] = artifact.version
            artifactsByNormalizedPath[path, default: []].append(artifact)
        }

        // One `fileExists` per artifact, not two. The two filters were
        // complements of each other, so the second one re-stat'd every row the
        // first had just stat'd.
        var current: [Artifact] = []
        var stale: [Artifact] = []
        for artifact in task.artifacts {
            if artifactExists(artifact, fileManager: fileManager) {
                current.append(artifact)
            } else {
                stale.append(artifact)
            }
        }

        let summary = TaskArtifactReconciliationSummary(
            discoveredFiles: files,
            createdArtifacts: created,
            normalizedArtifacts: normalizedArtifacts,
            normalizedArtifactKinds: normalizedArtifactKinds,
            duplicateArtifacts: duplicateArtifacts(groupedByNormalizedPath: artifactsByNormalizedPath),
            currentArtifacts: current,
            staleArtifacts: stale
        )
        AuditLoggingSeam.required.audit(
            .runtimePersistenceSummary,
            category: "Worker",
            taskID: task.id,
            fields: summary.auditFields,
            level: summary.status == .unchanged ? .debug : .info
        )
        return summary
    }

    @discardableResult
    public static func persistDiscoveredTaskOutputArtifacts(
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        fileManager: FileManager = .default
    ) -> [Artifact] {
        reconcileTaskOutputArtifacts(for: task, modelContext: modelContext, fileManager: fileManager).createdArtifacts
    }

    @discardableResult
    public static func persistDiscoveredTaskOutputArtifacts(
        _ files: [TaskOutputDiscoveredFile],
        for task: AgentTask,
        modelContext: ModelContext? = nil
    ) -> [Artifact] {
        reconcileTaskOutputArtifacts(files, for: task, modelContext: modelContext).createdArtifacts
    }

    @discardableResult
    public static func persistFileChangeArtifact(
        _ change: StoredFileChange,
        for task: AgentTask,
        modelContext: ModelContext? = nil
    ) -> Artifact? {
        let path = normalizedPath(change.path, task: task)
        guard !path.isEmpty,
              shouldPersistFileChangeArtifact(path, for: task) else { return nil }
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

    private static func shouldPersistFileChangeArtifact(_ path: String, for task: AgentTask) -> Bool {
        let access = TaskWorkspaceAccess(task: task)
        if let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: access.taskFolder) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }
        if let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: access.effectiveWorkspacePath) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .workspace
            ) != nil
        }
        return true
    }

    private static func nextVersion(for normalizedPath: String, task: AgentTask) -> Int {
        (task.artifacts
            .filter { Self.normalizedPath($0.path, task: task) == normalizedPath }
            .map(\.version)
            .max() ?? 0) + 1
    }

    private static func insertArtifact(_ artifact: Artifact, into task: AgentTask, modelContext: ModelContext?) {
        var heldArtifactIDs = Set(task.artifacts.map(\.id))
        insertArtifact(artifact, into: task, modelContext: modelContext, heldArtifactIDs: &heldArtifactIDs)
    }

    /// The bulk form. `heldArtifactIDs` carries the membership test across
    /// calls so appending *n* artifacts costs *n* lookups rather than a linear
    /// scan of the relationship each time.
    private static func insertArtifact(
        _ artifact: Artifact,
        into task: AgentTask,
        modelContext: ModelContext?,
        heldArtifactIDs: inout Set<UUID>
    ) {
        modelContext?.insert(artifact)
        guard heldArtifactIDs.insert(artifact.id).inserted else { return }
        task.artifacts.append(artifact)
    }

    private static func duplicateArtifacts(
        groupedByNormalizedPath grouped: [String: [Artifact]]
    ) -> [Artifact] {
        // The key is already the normalized path, which is what the emptiness
        // test used to recompute off the first member of each group.
        grouped.flatMap { path, artifacts -> [Artifact] in
            guard !path.isEmpty else { return [] }
            let sorted = artifacts.sorted {
                if $0.version == $1.version {
                    return $0.createdAt < $1.createdAt
                }
                return $0.version < $1.version
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
