import Foundation
import CryptoKit
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct TaskForkManifest: Codable, Sendable, Equatable {
    struct FileReference: Codable, Sendable, Equatable, Hashable {
        var kind: String
        var sourcePath: String
        var localCopyPath: String?
        var size: Int?
        var modifiedAt: Date?
        var sha256: String?
        var originatingRunID: UUID?
        var logicalPath: String?
    }

    struct RepositoryContext: Codable, Sendable, Equatable {
        var rootPath: String
        var branch: String
        var headSHA: String
        var isDirty: Bool
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
    var sourceInputs: [FileReference]?
    var sourceAttachments: [FileReference]?
    var forkMode: String?
    var repository: RepositoryContext?
    var createdAt: Date

    var resolvedForkMode: TaskForkMode {
        TaskForkMode(rawValue: forkMode ?? "") ?? .conversationSharedFiles
    }

    var allFileReferences: [FileReference] {
        sourceOutputFiles + sourceArtifacts + (sourceInputs ?? []) + (sourceAttachments ?? [])
    }
}

enum TaskForkManifestService: Sendable {
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
        mode: TaskForkMode = .conversationSharedFiles,
        repository: TaskForkRepositorySnapshot? = nil,
        sourceAttachments: [String] = [],
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
        var manifest = TaskForkManifest(
            schemaVersion: 2,
            sourceTaskID: source.id,
            forkedTaskID: forked.id,
            checkpointRunID: targetRun.id,
            checkpointRunIndex: checkpointRunIndex,
            copiedRunIDs: copiedRunIDs,
            sourceTaskFolder: sourceFolder,
            sourceSessionHistoryPath: sourceSessionHistory,
            checkpointSessionHistoryPath: checkpointSessionHistorySnapshot(
                sourceFolder: sourceFolder,
                sourceSessionHistoryPath: sourceSessionHistory,
                copiedRunCount: copiedRunCount,
                forkFolder: forkFolder,
                fileManager: fileManager
            ),
            sourceOutputFiles: sourceOutputFiles(
                sourceFolder: sourceFolder,
                copiedRunIDs: copiedRunIDs,
                fileManager: fileManager
            ),
            sourceArtifacts: sourceArtifactFiles(
                source: source,
                sourceFolder: sourceFolder,
                cutoffDate: cutoffDate,
                fileManager: fileManager
            ),
            sourceInputs: source.inputs.compactMap {
                fileReference(kind: "input", path: $0, requireExists: false, fileManager: fileManager)
            },
            sourceAttachments: dedupe(sourceAttachments).compactMap {
                fileReference(kind: "attachment", path: $0, requireExists: false, fileManager: fileManager)
            },
            forkMode: mode.rawValue,
            repository: repository.map {
                TaskForkManifest.RepositoryContext(
                    rootPath: $0.rootPath,
                    branch: $0.branch,
                    headSHA: $0.headSHA,
                    isDirty: $0.isDirty
                )
            },
            createdAt: Date()
        )
        if mode == .conversationWithFileCopies {
            try snapshotFiles(in: &manifest, forkFolder: forkFolder, fileManager: fileManager)
            rewriteForkLocalTextFiles(in: manifest, forkFolder: forkFolder, fileManager: fileManager)
        }
        try save(manifest, taskFolder: forkFolder, fileManager: fileManager)
        return manifest
    }

    /// ASTRA-generated fork-local text (the checkpoint history snapshot and
    /// copied `turn_*.md` outputs) is advertised to follow-up prompts, so
    /// mentions of copied source paths inside it must point at the fork-local
    /// copies or the agent gets sent back to the shared originals despite
    /// file-copy mode. Copies of user files (inputs, attachments) are never
    /// content-rewritten.
    private static func rewriteForkLocalTextFiles(
        in manifest: TaskForkManifest,
        forkFolder: String,
        fileManager: FileManager
    ) {
        let baseMapping = manifest.allFileReferences.reduce(into: [String: String]()) { mapping, reference in
            if let local = reference.localCopyPath {
                mapping[reference.sourcePath] = local
            }
        }
        let mapping = AgentTaskForkService.expandedRewriteMapping(baseMapping, originalSpellings: [])
        guard !mapping.isEmpty else { return }
        var targets = manifest.sourceOutputFiles.compactMap(\.localCopyPath)
        if let historyPath = manifest.checkpointSessionHistoryPath {
            targets.append(historyPath)
        }
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(
            root: URL(fileURLWithPath: forkFolder, isDirectory: true)
        )
        for path in targets {
            guard let contents = try? hostFileAccess.readString(
                at: URL(fileURLWithPath: path),
                encoding: .utf8,
                intent: accessIntent
            ) else { continue }
            let rewritten = AgentTaskForkService.replacingPaths(in: contents, using: mapping)
            if rewritten != contents {
                try? rewritten.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    static func load(for task: AgentTask, fileManager: FileManager = .default) -> TaskForkManifest? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return nil }
        return load(taskFolder: folder, fileManager: fileManager)
    }

    /// Primitive-ized for `TaskForkSourcePointerSeam`: the flattened checkpoint
    /// file paths `WorkspaceFileIndexService` lists in the files shelf,
    /// without exposing `TaskForkManifest`/`FileReference` across the seam.
    static func checkpointFilePaths(for task: AgentTask, fileManager: FileManager) -> [String] {
        guard let manifest = load(for: task, fileManager: fileManager) else { return [] }
        return manifest.allFileReferences
            .map { $0.localCopyPath ?? $0.sourcePath }
    }

    static func load(taskFolder: String, fileManager: FileManager = .default) -> TaskForkManifest? {
        let path = manifestPath(taskFolder: taskFolder)
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: URL(fileURLWithPath: taskFolder, isDirectory: true))
        guard !path.isEmpty,
              let data = try? hostFileAccess.readData(
                at: URL(fileURLWithPath: path),
                intent: accessIntent
              ) else {
            return nil
        }
        return try? JSONDecoder().decode(TaskForkManifest.self, from: data)
    }

    static func sourcePointers(for task: AgentTask) -> [TaskContextSourcePointer] {
        guard let manifest = load(for: task) else { return [] }
        var pointers: [TaskContextSourcePointer] = []
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
        pointers += (manifest.sourceInputs ?? []).map {
            pointer(
                kind: "fork_source_input",
                id: manifest.sourceTaskID.uuidString,
                path: $0.localCopyPath ?? $0.sourcePath,
                summary: "Conversation fork input"
            )
        }
        pointers += (manifest.sourceAttachments ?? []).map {
            pointer(
                kind: "fork_source_attachment",
                id: manifest.sourceTaskID.uuidString,
                path: $0.localCopyPath ?? $0.sourcePath,
                summary: "Conversation fork attachment"
            )
        }
        return pointers
    }

    static func sourceAvailabilityWarning(for task: AgentTask, fileManager: FileManager = .default) -> String? {
        guard let manifest = load(for: task, fileManager: fileManager) else { return nil }
        return sourceAvailabilityWarning(for: manifest, fileManager: fileManager)
    }

    static func sourceAvailabilityWarning(
        for manifest: TaskForkManifest,
        fileManager: FileManager = .default
    ) -> String? {
        let references = manifest.allFileReferences
        let missing = references.contains { ref in
            if let local = ref.localCopyPath, fileManager.fileExists(atPath: local) {
                return false
            }
            return !fileManager.fileExists(atPath: ref.sourcePath)
        }
        guard missing else { return nil }

        if !manifest.sourceTaskFolder.isEmpty,
           !fileManager.fileExists(atPath: manifest.sourceTaskFolder) {
            return "Checkpoint files are unavailable; using saved task history."
        }
        return "Some checkpoint files are unavailable; using saved task history for missing files."
    }

    @discardableResult
    static func materializeSourceFile(
        sourcePath: String,
        for task: AgentTask,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard var manifest = load(for: task, fileManager: fileManager) else { return nil }
        let references = manifest.allFileReferences
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
        try fileManager.copyItem(atPath: resolvedCopySource(for: reference.sourcePath), toPath: destination)

        if let outputIndex = manifest.sourceOutputFiles.firstIndex(where: { $0.sourcePath == sourcePath }) {
            manifest.sourceOutputFiles[outputIndex].localCopyPath = destination
        }
        if let artifactIndex = manifest.sourceArtifacts.firstIndex(where: { $0.sourcePath == sourcePath }) {
            manifest.sourceArtifacts[artifactIndex].localCopyPath = destination
        }
        if let inputIndex = manifest.sourceInputs?.firstIndex(where: { $0.sourcePath == sourcePath }) {
            manifest.sourceInputs?[inputIndex].localCopyPath = destination
        }
        if let attachmentIndex = manifest.sourceAttachments?.firstIndex(where: { $0.sourcePath == sourcePath }) {
            manifest.sourceAttachments?[attachmentIndex].localCopyPath = destination
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
        copiedRunIDs: [UUID],
        fileManager: FileManager
    ) -> [TaskForkManifest.FileReference] {
        guard !copiedRunIDs.isEmpty else { return [] }
        let outputFolder = (sourceFolder as NSString).appendingPathComponent("outputs")
        let sourceRoot = URL(fileURLWithPath: sourceFolder, isDirectory: true)
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: sourceRoot)
        guard let names = try? hostFileAccess.contentsOfDirectory(
            at: URL(fileURLWithPath: outputFolder, isDirectory: true),
            intent: accessIntent
        ).map(\.lastPathComponent) else { return [] }
        return names
            .filter { $0.hasPrefix("turn_") && $0.hasSuffix(".md") }
            .sorted()
            .prefix(copiedRunIDs.count)
            .enumerated()
            .compactMap { index, name in
                var reference = fileReference(
                    kind: "output",
                    path: (outputFolder as NSString).appendingPathComponent(name),
                    fileManager: fileManager
                )
                reference?.originatingRunID = copiedRunIDs[index]
                return reference
            }
    }

    private static func checkpointSessionHistorySnapshot(
        sourceFolder: String,
        sourceSessionHistoryPath: String?,
        copiedRunCount: Int,
        forkFolder: String,
        fileManager: FileManager
    ) -> String? {
        let sourceRoot = URL(fileURLWithPath: sourceFolder, isDirectory: true)
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: sourceRoot)
        guard copiedRunCount > 0,
              let sourceSessionHistoryPath,
              let history = try? hostFileAccess.readString(
                at: URL(fileURLWithPath: sourceSessionHistoryPath),
                encoding: .utf8,
                intent: accessIntent
              ) else {
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
        paths += TaskGeneratedFiles.files(in: sourceFolder, fileManager: fileManager).filter { path in
            guard let modifiedAt = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date else {
                return false
            }
            return modifiedAt <= cutoffDate
        }
        return dedupe(paths)
            .compactMap {
                fileReference(kind: "artifact", path: $0, fileManager: fileManager)
            }
    }

    /// `requireExists: false` records declared-but-missing files (inputs and
    /// attachments) so `sourceAvailabilityWarning` can report them; discovered
    /// files (outputs, artifacts) keep requiring existence.
    private static func fileReference(
        kind: String,
        path: String,
        requireExists: Bool = true,
        fileManager: FileManager
    ) -> TaskForkManifest.FileReference? {
        guard !path.isEmpty else { return nil }
        guard fileManager.fileExists(atPath: path) || !requireExists else { return nil }
        let attrs = try? fileManager.attributesOfItem(atPath: path)
        return TaskForkManifest.FileReference(
            kind: kind,
            sourcePath: path,
            localCopyPath: nil,
            size: (attrs?[.size] as? NSNumber)?.intValue,
            modifiedAt: attrs?[.modificationDate] as? Date,
            // Hashing every referenced file would read it fully into memory on
            // the main actor even in shared-files mode, where nothing consumes
            // the digest. `snapshotReferences` hashes the fork-local copy when
            // file-copy mode actually materializes one.
            sha256: nil,
            originatingRunID: nil,
            logicalPath: (path as NSString).lastPathComponent
        )
    }

    private static func snapshotFiles(
        in manifest: inout TaskForkManifest,
        forkFolder: String,
        fileManager: FileManager
    ) throws {
        // One local copy per distinct source file, shared across reference
        // classes: a file that is both an input and an attachment must map to
        // a single copy or fork edits diverge between the two "copies".
        var copiesBySource: [String: (path: String, sha256: String?)] = [:]
        try snapshotReferences(&manifest.sourceOutputFiles, forkFolder: forkFolder, copiesBySource: &copiesBySource, fileManager: fileManager)
        try snapshotReferences(&manifest.sourceArtifacts, forkFolder: forkFolder, copiesBySource: &copiesBySource, fileManager: fileManager)
        var inputs = manifest.sourceInputs ?? []
        try snapshotReferences(&inputs, forkFolder: forkFolder, copiesBySource: &copiesBySource, fileManager: fileManager)
        manifest.sourceInputs = inputs
        var attachments = manifest.sourceAttachments ?? []
        try snapshotReferences(&attachments, forkFolder: forkFolder, copiesBySource: &copiesBySource, fileManager: fileManager)
        manifest.sourceAttachments = attachments
    }

    private static func snapshotReferences(
        _ references: inout [TaskForkManifest.FileReference],
        forkFolder: String,
        copiesBySource: inout [String: (path: String, sha256: String?)],
        fileManager: FileManager
    ) throws {
        for index in references.indices {
            let sourcePath = references[index].sourcePath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let canonicalKey = canonicalPathKey(sourcePath)
            if let existing = copiesBySource[canonicalKey] {
                references[index].localCopyPath = existing.path
                references[index].sha256 = existing.sha256
                continue
            }
            let copyRoot = (forkFolder as NSString).appendingPathComponent("fork_sources")
            let kindRoot = (copyRoot as NSString).appendingPathComponent(references[index].kind)
            try fileManager.createDirectory(atPath: kindRoot, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: sourcePath, in: kindRoot, fileManager: fileManager)
            try fileManager.copyItem(atPath: resolvedCopySource(for: sourcePath), toPath: destination)
            references[index].localCopyPath = destination
            references[index].sha256 = sha256(path: destination, managedRoot: forkFolder, fileManager: fileManager)
            copiesBySource[canonicalKey] = (destination, references[index].sha256)
        }
    }

    /// `FileManager.copyItem` reproduces a symlink as a symlink, which would
    /// leave an "independent copy" aliased to the live original. Resolving
    /// first snapshots the target's content instead. Symlinked directories
    /// never reach the copy calls (the `fileExists(isDirectory:)` guards
    /// traverse links, so they take the shared-reference path).
    private static func resolvedCopySource(for sourcePath: String) -> String {
        URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path
    }

    private static func sha256(path: String, managedRoot: String? = nil, fileManager: FileManager) -> String? {
        let broker = HostFileAccessBroker(fileManager: fileManager)
        guard let data = try? broker.readData(
            at: URL(fileURLWithPath: path),
            intent: managedRoot.map {
                .astraManagedStorage(root: URL(fileURLWithPath: $0, isDirectory: true))
            } ?? .explicitUserSelection
        ) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func existingPath(_ path: String, fileManager: FileManager) -> String? {
        !path.isEmpty && fileManager.fileExists(atPath: path) ? path : nil
    }

    private static func pointer(
        kind: String,
        id: String?,
        path: String? = nil,
        summary: String
    ) -> TaskContextSourcePointer {
        TaskContextSourcePointer(kind: kind, id: id, path: path, summary: summary)
    }

    private static func canonicalPathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard seen.insert(canonicalPathKey(path)).inserted else { return nil }
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

/// Registered as the `TaskForkManifestWritingSeam`
/// (`ASTRACore/TaskForkLifecycleSeams.swift`) backing implementation - see
/// that file's header for why this reconstructs scratch, never-persisted
/// `AgentTask`/`TaskRun`/`Artifact`/`Workspace` instances from
/// `TaskForkManifestRequest` and runs the real, unchanged
/// `TaskForkManifestService.writeManifest(source:forked:targetRun:...)` on
/// them, rather than re-deriving its file-I/O logic as primitives.
enum TaskForkManifestWritingAdapter: TaskForkManifestWriting {
    static func writeManifest(_ request: TaskForkManifestRequest) throws -> TaskForkManifestSummary {
        let sourceWorkspace = Workspace(name: "fork-source-scratch", primaryPath: request.sourceWorkspacePath)
        let source = AgentTask(title: "", goal: "", workspace: sourceWorkspace)
        source.id = request.sourceTaskID
        source.artifacts = request.sourceArtifacts.map { fact in
            let artifact = Artifact(task: source, type: "file", path: fact.path)
            artifact.createdAt = fact.createdAt
            return artifact
        }
        source.inputs = request.sourceInputs

        let forkedWorkspace = Workspace(name: "fork-scratch", primaryPath: request.forkedWorkspacePath)
        let forked = AgentTask(title: "", goal: "", workspace: forkedWorkspace)
        forked.id = request.forkedTaskID

        let targetRun = TaskRun(task: forked)
        targetRun.id = request.checkpointRunID
        targetRun.startedAt = request.checkpointRunStartedAt
        targetRun.completedAt = request.checkpointRunCompletedAt

        let manifest = try TaskForkManifestService.writeManifest(
            source: source,
            forked: forked,
            targetRun: targetRun,
            checkpointRunIndex: request.checkpointRunIndex,
            copiedRunIDs: request.copiedRunIDs,
            mode: TaskForkMode(rawValue: request.forkModeRawValue) ?? .conversationSharedFiles,
            repository: request.repository.map {
                TaskForkRepositorySnapshot(
                    rootPath: $0.rootPath,
                    branch: $0.branch,
                    headSHA: $0.headSHA,
                    isDirty: $0.isDirty
                )
            },
            sourceAttachments: request.sourceAttachments
        )
        let sourceToLocalPaths = manifest.allFileReferences.reduce(into: [String: String]()) { mapping, reference in
            if let localCopyPath = reference.localCopyPath {
                mapping[reference.sourcePath] = localCopyPath
            }
        }
        return TaskForkManifestSummary(
            sourceTaskID: manifest.sourceTaskID,
            checkpointRunID: manifest.checkpointRunID,
            checkpointRunIndex: manifest.checkpointRunIndex,
            sourceToLocalPaths: sourceToLocalPaths
        )
    }

    static func manifestPath(taskFolder: String) -> String {
        TaskForkManifestService.manifestPath(taskFolder: taskFolder)
    }

    static func removePreparedFork(taskFolder: String) {
        guard !taskFolder.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: taskFolder)
    }
}
