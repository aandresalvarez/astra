import Foundation
import ASTRAModels
import ASTRACore

public struct TaskOutputDiscoveredFile: Hashable {
    public init(path: String, relativePath: String, type: String, modifiedAt: Date? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.type = type
        self.modifiedAt = modifiedAt
    }

    public var path: String
    public var relativePath: String
    public var type: String
    public var modifiedAt: Date?

    public var kind: ArtifactKind {
        ArtifactKind(rawValue: type)
    }
}

public enum TaskOutputDiscovery {
    @MainActor
    public static func files(for task: AgentTask, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
        files(in: TaskWorkspaceAccess(task: task).taskFolder, fileManager: fileManager)
    }

    @MainActor
    public static func files(
        for task: AgentTask,
        run: TaskRun?,
        workspacePath: String? = nil,
        fileManager: FileManager = .default
    ) -> [TaskOutputDiscoveredFile] {
        var discovered = files(for: task, fileManager: fileManager)
        guard let run else { return discovered }

        var seen = Set(discovered.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let taskAccess = TaskWorkspaceAccess(task: task)
        let executionPath = workspacePath ?? taskAccess.effectiveWorkspacePath

        // Resolved once for the loop: `discoveredRunFile` compares each path
        // against both roots in standardized *and* symlink-resolved form, and
        // re-resolving the roots per file change is pure repetition.
        let roots = RunFileRoots(taskFolder: taskAccess.taskFolder, workspacePath: executionPath)
        for change in run.fileChanges {
            guard let file = discoveredRunFile(
                path: change.path,
                roots: roots,
                fileManager: fileManager
            ) else { continue }
            guard seen.insert(URL(fileURLWithPath: file.path).standardizedFileURL.path).inserted else { continue }
            discovered.append(file)
        }
        let workspaceFiles = TaskOutputWorkspaceDiscovery.filesChangedDuringRun(
            workspacePath: executionPath,
            taskFolder: taskAccess.taskFolder,
            run: run,
            fileManager: fileManager
        )
        for file in workspaceFiles {
            guard seen.insert(URL(fileURLWithPath: file.path).standardizedFileURL.path).inserted else { continue }
            discovered.append(file)
        }

        return discovered.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    @MainActor
    public static func filesAsync(for task: AgentTask, fileManager: FileManager = .default) async -> [TaskOutputDiscoveredFile] {
        await filesAsync(in: TaskWorkspaceAccess(task: task).taskFolder, fileManager: fileManager)
    }

    public static func filesAsync(in taskFolder: String, fileManager: FileManager = .default) async -> [TaskOutputDiscoveredFile] {
        await Task.detached(priority: .utility) {
            files(in: taskFolder, fileManager: fileManager)
        }.value
    }

    public static func files(in taskFolder: String, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
        guard !taskFolder.isEmpty else { return [] }
        let folderURL = URL(fileURLWithPath: taskFolder)
        let folderPath = folderURL.standardizedFileURL.path
        let resolvedFolderPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard fileManager.fileExists(atPath: folderPath) else { return [] }

        return TaskGeneratedFileQuerySeam.required.files(in: folderPath, fileManager: fileManager)
            .compactMap { path in
                discoveredFile(
                    path: path,
                    taskFolderPath: folderPath,
                    resolvedTaskFolderPath: resolvedFolderPath,
                    fileManager: fileManager
                )
            }
            .sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
    }

    public static func filesChanged(during run: TaskRun, from files: [TaskOutputDiscoveredFile]) -> [TaskOutputDiscoveredFile] {
        let lowerBound = run.startedAt.addingTimeInterval(-2)
        let upperBound = (run.completedAt ?? Date()).addingTimeInterval(2)
        return files.filter { file in
            guard let modifiedAt = file.modifiedAt else { return false }
            return modifiedAt >= lowerBound && modifiedAt <= upperBound
        }
    }

    private static func discoveredFile(
        path: String,
        taskFolderPath: String,
        resolvedTaskFolderPath: String,
        fileManager: FileManager
    ) -> TaskOutputDiscoveredFile? {
        let url = URL(fileURLWithPath: path)
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath == taskFolderPath || standardizedPath.hasPrefix(taskFolderPath + "/") else {
            return nil
        }

        // Classify first: the visibility test is string work, and the three
        // checks below it are a stat, a symlink resolve, and an attribute read.
        // Paying those for a path that is about to be discarded is the whole
        // cost of a folder full of generated files.
        guard let relative = TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
            String(standardizedPath.dropFirst(taskFolderPath.count)),
            context: .taskFolder
        ) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == resolvedTaskFolderPath || resolvedPath.hasPrefix(resolvedTaskFolderPath + "/") else {
            return nil
        }

        let attrs = try? fileManager.attributesOfItem(atPath: standardizedPath)
        return TaskOutputDiscoveredFile(
            path: standardizedPath,
            relativePath: relative,
            type: ArtifactKind.forPath(standardizedPath).rawValue,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    /// The task folder and workspace roots a run's file changes are matched
    /// against, each resolved once for the whole run.
    private struct RunFileRoots {
        let candidates: [(root: TaskOutputArtifactPathPolicy.ResolvedRoot, context: TaskOutputArtifactPathPolicy.RelativePathContext)]

        init(taskFolder: String, workspacePath: String) {
            candidates = [
                (.init(taskFolder), .taskFolder),
                (.init(workspacePath), .workspace)
            ].filter { !$0.0.isEmpty }
        }
    }

    private static func discoveredRunFile(
        path: String,
        roots: RunFileRoots,
        fileManager: FileManager
    ) -> TaskOutputDiscoveredFile? {
        let url = URL(fileURLWithPath: path)
        let standardizedPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

        guard let match = matchedRoot(
            standardizedPath: standardizedPath,
            resolvedPath: resolvedPath,
            roots: roots
        ) else {
            return nil
        }

        let rootPath = match.root
        guard let relative = TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
            String(standardizedPath.dropFirst(rootPath.count)),
            context: match.context
        ) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let attrs = try? fileManager.attributesOfItem(atPath: standardizedPath)
        return TaskOutputDiscoveredFile(
            path: standardizedPath,
            relativePath: relative,
            type: ArtifactKind.forPath(standardizedPath).rawValue,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    private static func matchedRoot(
        standardizedPath: String,
        resolvedPath: String,
        roots: RunFileRoots
    ) -> (root: String, context: TaskOutputArtifactPathPolicy.RelativePathContext)? {
        for (root, context) in roots.candidates {
            if (standardizedPath == root.standardized || standardizedPath.hasPrefix(root.standardized + "/")) &&
                (resolvedPath == root.resolved || resolvedPath.hasPrefix(root.resolved + "/")) {
                return (root.standardized, context)
            }
        }
        return nil
    }
}
