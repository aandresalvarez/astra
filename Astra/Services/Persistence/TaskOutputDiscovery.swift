import Foundation
import os
import ASTRAModels
import ASTRACore

public struct TaskOutputDiscoveredFile: Hashable, Sendable {
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
            guard let path = resolvedChangePath(change, workspacePath: executionPath, taskFolder: taskAccess.taskFolder),
                  let file = discoveredRunFile(
                path: path,
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

    /// The absolute path a recorded change names. A tool reports paths
    /// relative to the run's working directory; a task-folder snapshot records
    /// them relative to the task folder. Left unresolved, a relative path was
    /// read against the app's own working directory and matched nothing.
    public static func resolvedChangePath(
        _ change: StoredFileChange,
        workspacePath: String,
        taskFolder: String
    ) -> String? {
        let path = change.path.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        let root = change.kind.isObserved ? taskFolder : workspacePath
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
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

    public struct Preparation: Sendable {
        public let files: [TaskOutputDiscoveredFile]
        /// The same scan with every per-path answer the context derive asks
        /// for, when the caller named the workspace and the paths to settle.
        /// Nil from the plain `prepareAsync(in:)`.
        public var observation: TaskOutputObservation? = nil
        /// The folder that was scanned. `files` are absolute paths inside it,
        /// so they describe the task only while this is still its folder.
        public var taskFolder: String? = nil
        public let requestedAt: UInt64
        public let startedAt: UInt64
        public let finishedAt: UInt64

        public func phaseMilliseconds(resumedAt: UInt64) -> [String: Double] {
            ["output_discovery_queue": Double(startedAt - requestedAt) / 1_000_000,
             "output_discovery_io": Double(finishedAt - startedAt) / 1_000_000,
             "output_discovery_resume": Double(max(finishedAt, resumedAt) - finishedAt) / 1_000_000]
        }
    }

    public static func prepareAsync(in taskFolder: String) async -> Preparation {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        return await Task.detached(priority: .utility) {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let files = files(in: taskFolder)
            var preparation = Preparation(files: files, requestedAt: requestedAt, startedAt: startedAt,
                finishedAt: DispatchTime.now().uptimeNanoseconds)
            preparation.taskFolder = taskFolder
            return preparation
        }.value
    }

    /// `prepareAsync(in:)` that also settles what the context derive asks
    /// about `candidatePaths` and about the files it finds, so the main actor
    /// can refresh the task's context without touching the folder again.
    public static func prepareAsync(
        in taskFolder: String,
        workspacePath: String,
        candidatePaths: [String]
    ) async -> Preparation {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        return await Task.detached(priority: .utility) {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            // The derive also filters the paths `current_state.json` already
            // remembers, and those can name a file that neither the model nor
            // the folder still does. Read here, as the off-actor refresh does,
            // or each one is a lookup back on the main actor.
            let remembered: [String] = taskFolder.isEmpty
                ? []
                : TaskContextStateManager.loadResult(taskFolder: taskFolder).state?.filesChanged ?? []
            let observation = TaskOutputObservation.observe(
                taskFolder: taskFolder,
                workspacePath: workspacePath,
                paths: candidatePaths + remembered
            )
            let discovered = observation?.discoveredFiles ?? files(in: taskFolder)
            var preparation = Preparation(files: discovered, requestedAt: requestedAt, startedAt: startedAt,
                finishedAt: DispatchTime.now().uptimeNanoseconds)
            preparation.observation = observation
            preparation.taskFolder = taskFolder
            return preparation
        }.value
    }

    public static func files(in taskFolder: String, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
        files(in: taskFolder, fileManager: fileManager, isCancelled: { false }) ?? []
    }

    /// `files(in:)` that polls `isCancelled` per entry and returns nil once it
    /// says so, for a caller that will discard a cancelled result anyway.
    public static func files(
        in taskFolder: String,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool
    ) -> [TaskOutputDiscoveredFile]? {
        guard !taskFolder.isEmpty else { return [] }
        let folderURL = URL(fileURLWithPath: taskFolder)
        let folderPath = folderURL.standardizedFileURL.path
        let resolvedFolderPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard fileManager.fileExists(atPath: folderPath) else { return [] }

        #if DEBUG
        walkCountsForTesting.withLock { counts in
            if let count = counts[folderPath] { counts[folderPath] = count + 1 }
        }
        #endif
        guard let paths = TaskGeneratedFileQuerySeam.required.files(
            in: folderPath,
            fileManager: fileManager,
            isCancelled: isCancelled
        ) else { return nil }
        var discovered: [TaskOutputDiscoveredFile] = []
        for path in paths {
            guard !isCancelled() else { return nil }
            guard let file = discoveredFile(
                path: path,
                taskFolderPath: folderPath,
                resolvedTaskFolderPath: resolvedFolderPath,
                fileManager: fileManager
            ) else { continue }
            discovered.append(file)
        }
        return discovered.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    #if DEBUG
    /// Walks of a folder, whoever asked for them and on whichever thread, for
    /// the folders a test is counting. Per folder, so suites that run in
    /// parallel never see each other's walks.
    private static let walkCountsForTesting = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    private static func walkCountKey(_ taskFolder: String) -> String {
        URL(fileURLWithPath: taskFolder).standardizedFileURL.path
    }

    /// Starts, or restarts, the count for `taskFolder` at zero.
    static func countWalksForTesting(in taskFolder: String) {
        let key = walkCountKey(taskFolder)
        walkCountsForTesting.withLock { $0[key] = 0 }
    }

    static func walkCountForTesting(in taskFolder: String) -> Int {
        let key = walkCountKey(taskFolder)
        return walkCountsForTesting.withLock { $0[key] ?? 0 }
    }

    static func stopCountingWalksForTesting(in taskFolder: String) {
        let key = walkCountKey(taskFolder)
        walkCountsForTesting.withLock { $0[key] = nil }
    }
    #endif

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
