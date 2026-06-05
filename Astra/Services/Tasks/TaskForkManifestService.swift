import Foundation

struct TaskForkManifest: Codable, Sendable, Equatable {
    struct FileReference: Codable, Sendable, Equatable, Hashable {
        var kind: String
        var sourcePath: String
        var localCopyPath: String?
        var size: Int?
        var modifiedAt: Date?
    }

    static let fileName = "fork_manifest.json"

    var schemaVersion: Int
    var sourceTaskID: UUID
    var forkedTaskID: UUID
    var checkpointRunID: UUID
    var checkpointRunIndex: Int
    var copiedRunIDs: [UUID]
    var sourceTaskFolder: String
    var sourceSessionHistoryPath: String?
    var checkpointSessionHistoryPath: String?
    var sourceOutputFiles: [FileReference]
    var sourceArtifacts: [FileReference]
    var createdAt: Date
}

enum TaskForkManifestService {
    static func manifestPath(taskFolder: String) -> String {
        guard !taskFolder.isEmpty else { return "" }
        return (taskFolder as NSString).appendingPathComponent(TaskForkManifest.fileName)
    }

    @discardableResult
    static func writeManifest(
        source: AgentTask,
        forked: AgentTask,
        targetRun: TaskRun,
        checkpointRunIndex: Int,
        copiedRunIDs: [UUID],
        fileManager: FileManager = .default
    ) throws -> TaskForkManifest {
        let forkFolder = try TaskWorkspaceAccess(task: forked).ensureTaskFolder()
        let sourceFolder = TaskWorkspaceAccess(task: source).taskFolder
        let cutoffDate = targetRun.completedAt ?? targetRun.startedAt
        let copiedRunCount = max(0, copiedRunIDs.count)
        let sourceSessionHistory = existingPath(
            SessionHistoryManager.historyPath(taskFolder: sourceFolder),
            fileManager: fileManager
        )
        let manifest = TaskForkManifest(
            schemaVersion: 1,
            sourceTaskID: source.id,
            forkedTaskID: forked.id,
            checkpointRunID: targetRun.id,
            checkpointRunIndex: checkpointRunIndex,
            copiedRunIDs: copiedRunIDs,
            sourceTaskFolder: sourceFolder,
            sourceSessionHistoryPath: sourceSessionHistory,
            checkpointSessionHistoryPath: checkpointSessionHistorySnapshot(
                sourceSessionHistoryPath: sourceSessionHistory,
                copiedRunCount: copiedRunCount,
                forkFolder: forkFolder,
                fileManager: fileManager
            ),
            sourceOutputFiles: sourceOutputFiles(
                sourceFolder: sourceFolder,
                copiedRunCount: copiedRunCount,
                fileManager: fileManager
            ),
            sourceArtifacts: sourceArtifactFiles(
                source: source,
                sourceFolder: sourceFolder,
                cutoffDate: cutoffDate,
                fileManager: fileManager
            ),
            createdAt: Date()
        )
        try save(manifest, taskFolder: forkFolder, fileManager: fileManager)
        return manifest
    }

    static func load(for task: AgentTask, fileManager: FileManager = .default) -> TaskForkManifest? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return nil }
        return load(taskFolder: folder, fileManager: fileManager)
    }

    static func load(taskFolder: String, fileManager: FileManager = .default) -> TaskForkManifest? {
        let path = manifestPath(taskFolder: taskFolder)
        guard !path.isEmpty,
              let data = fileManager.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(TaskForkManifest.self, from: data)
    }

    static func sourcePointers(for task: AgentTask) -> [TaskContextState.SourcePointer] {
        guard let manifest = load(for: task) else { return [] }
        var pointers: [TaskContextState.SourcePointer] = []
        let forkFolder = TaskWorkspaceAccess(task: task).taskFolder
        let path = manifestPath(taskFolder: forkFolder)
        if !path.isEmpty {
            pointers.append(pointer(
                kind: "fork_manifest",
                id: manifest.sourceTaskID.uuidString,
                path: path,
                summary: "Fork checkpoint manifest"
            ))
        }
        if !manifest.sourceTaskFolder.isEmpty {
            pointers.append(pointer(
                kind: "fork_source_folder",
                id: manifest.sourceTaskID.uuidString,
                path: manifest.sourceTaskFolder,
                summary: "Source task folder at fork checkpoint"
            ))
        }
        if let historyPath = manifest.checkpointSessionHistoryPath {
            pointers.append(pointer(
                kind: "fork_checkpoint_history",
                id: manifest.sourceTaskID.uuidString,
                path: historyPath,
                summary: "Fork-local session history through checkpoint"
            ))
        }
        pointers += manifest.sourceOutputFiles.map {
            pointer(
                kind: "fork_source_output",
                id: manifest.sourceTaskID.uuidString,
                path: $0.localCopyPath ?? $0.sourcePath,
                summary: "Source checkpoint turn output"
            )
        }
        pointers += manifest.sourceArtifacts.map {
            pointer(
                kind: "fork_source_artifact",
                id: manifest.sourceTaskID.uuidString,
                path: $0.localCopyPath ?? $0.sourcePath,
                summary: "Source checkpoint artifact"
            )
        }
        return pointers
    }

    static func sourceAvailabilityWarning(for task: AgentTask, fileManager: FileManager = .default) -> String? {
        guard let manifest = load(for: task, fileManager: fileManager) else { return nil }
        if !manifest.sourceTaskFolder.isEmpty,
           !fileManager.fileExists(atPath: manifest.sourceTaskFolder) {
            return "Checkpoint files are unavailable; using saved task history."
        }
        let references = manifest.sourceOutputFiles + manifest.sourceArtifacts
        let missing = references.contains { ref in
            if let local = ref.localCopyPath, fileManager.fileExists(atPath: local) {
                return false
            }
            return !fileManager.fileExists(atPath: ref.sourcePath)
        }
        return missing ? "Some checkpoint files are unavailable; using saved task history for missing files." : nil
    }

    @discardableResult
    static func materializeSourceFile(
        sourcePath: String,
        for task: AgentTask,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard var manifest = load(for: task, fileManager: fileManager) else { return nil }
        let references = manifest.sourceOutputFiles + manifest.sourceArtifacts
        guard let matchIndex = references.firstIndex(where: { $0.sourcePath == sourcePath }) else {
            return nil
        }
        let reference = references[matchIndex]
        if let local = reference.localCopyPath,
           fileManager.fileExists(atPath: local) {
            return local
        }
        guard fileManager.fileExists(atPath: reference.sourcePath) else { return nil }

        let forkFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let copyRoot = (forkFolder as NSString).appendingPathComponent("fork_sources")
        let kindRoot = (copyRoot as NSString).appendingPathComponent(reference.kind)
        try fileManager.createDirectory(atPath: kindRoot, withIntermediateDirectories: true)
        let destination = uniqueDestination(
            for: reference.sourcePath,
            in: kindRoot,
            fileManager: fileManager
        )
        try fileManager.copyItem(atPath: reference.sourcePath, toPath: destination)

        if let outputIndex = manifest.sourceOutputFiles.firstIndex(where: { $0.sourcePath == sourcePath }) {
            manifest.sourceOutputFiles[outputIndex].localCopyPath = destination
        }
        if let artifactIndex = manifest.sourceArtifacts.firstIndex(where: { $0.sourcePath == sourcePath }) {
            manifest.sourceArtifacts[artifactIndex].localCopyPath = destination
        }
        try save(manifest, taskFolder: forkFolder, fileManager: fileManager)
        return destination
    }

    private static func save(
        _ manifest: TaskForkManifest,
        taskFolder: String,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(atPath: taskFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath(taskFolder: taskFolder)), options: .atomic)
    }

    private static func sourceOutputFiles(
        sourceFolder: String,
        copiedRunCount: Int,
        fileManager: FileManager
    ) -> [TaskForkManifest.FileReference] {
        guard copiedRunCount > 0 else { return [] }
        let outputFolder = (sourceFolder as NSString).appendingPathComponent("outputs")
        guard let names = try? fileManager.contentsOfDirectory(atPath: outputFolder) else { return [] }
        return names
            .filter { $0.hasPrefix("turn_") && $0.hasSuffix(".md") }
            .sorted()
            .prefix(copiedRunCount)
            .compactMap { name in
                fileReference(
                    kind: "output",
                    path: (outputFolder as NSString).appendingPathComponent(name),
                    fileManager: fileManager
                )
            }
    }

    private static func checkpointSessionHistorySnapshot(
        sourceSessionHistoryPath: String?,
        copiedRunCount: Int,
        forkFolder: String,
        fileManager: FileManager
    ) -> String? {
        guard copiedRunCount > 0,
              let sourceSessionHistoryPath,
              let history = try? String(contentsOfFile: sourceSessionHistoryPath, encoding: .utf8) else {
            return nil
        }
        let marker = "\n## Turn "
        let pieces = history.components(separatedBy: marker)
        guard pieces.count > 1 else { return nil }
        let snapshot = ([pieces[0]] + pieces.dropFirst().prefix(copiedRunCount).map { "## Turn " + $0 })
            .joined(separator: "\n")
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let historyFolder = (forkFolder as NSString).appendingPathComponent("fork_sources/history")
        let destination = (historyFolder as NSString).appendingPathComponent("session_history_until_checkpoint.md")
        do {
            try fileManager.createDirectory(atPath: historyFolder, withIntermediateDirectories: true)
            try snapshot.write(toFile: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            return nil
        }
    }

    private static func sourceArtifactFiles(
        source: AgentTask,
        sourceFolder: String,
        cutoffDate: Date,
        fileManager: FileManager
    ) -> [TaskForkManifest.FileReference] {
        var paths = source.artifacts
            .filter { $0.createdAt <= cutoffDate }
            .map(\.path)
        paths += TaskGeneratedFiles.files(in: sourceFolder, fileManager: fileManager)
        return dedupe(paths)
            .compactMap {
                fileReference(kind: "artifact", path: $0, fileManager: fileManager)
            }
    }

    private static func fileReference(
        kind: String,
        path: String,
        fileManager: FileManager
    ) -> TaskForkManifest.FileReference? {
        guard !path.isEmpty, fileManager.fileExists(atPath: path) else { return nil }
        let attrs = try? fileManager.attributesOfItem(atPath: path)
        return TaskForkManifest.FileReference(
            kind: kind,
            sourcePath: path,
            localCopyPath: nil,
            size: (attrs?[.size] as? NSNumber)?.intValue,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    private static func existingPath(_ path: String, fileManager: FileManager) -> String? {
        !path.isEmpty && fileManager.fileExists(atPath: path) ? path : nil
    }

    private static func pointer(
        kind: String,
        id: String?,
        path: String? = nil,
        summary: String
    ) -> TaskContextState.SourcePointer {
        TaskContextState.SourcePointer(kind: kind, id: id, path: path, summary: summary)
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return path
        }
    }

    private static func uniqueDestination(
        for sourcePath: String,
        in directory: String,
        fileManager: FileManager
    ) -> String {
        let sourceName = (sourcePath as NSString).lastPathComponent
        let base = (sourceName as NSString).deletingPathExtension
        let ext = (sourceName as NSString).pathExtension
        var candidate = (directory as NSString).appendingPathComponent(sourceName)
        var index = 2
        while fileManager.fileExists(atPath: candidate) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = (directory as NSString).appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}
