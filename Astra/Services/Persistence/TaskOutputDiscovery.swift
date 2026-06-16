import Foundation

struct TaskOutputDiscoveredFile: Hashable {
    var path: String
    var relativePath: String
    var type: String
    var modifiedAt: Date?

    var kind: ArtifactKind {
        ArtifactKind(rawValue: type)
    }
}

enum TaskOutputDiscovery {
    @MainActor
    static func files(for task: AgentTask, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
        files(in: TaskWorkspaceAccess(task: task).taskFolder, fileManager: fileManager)
    }

    @MainActor
    static func files(
        for task: AgentTask,
        run: TaskRun?,
        fileManager: FileManager = .default
    ) -> [TaskOutputDiscoveredFile] {
        var discovered = files(for: task, fileManager: fileManager)
        guard let run else { return discovered }

        var seen = Set(discovered.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let taskAccess = TaskWorkspaceAccess(task: task)
        let allowedRoots = [taskAccess.taskFolder, taskAccess.effectiveWorkspacePath]
            .filter { !$0.isEmpty }

        for change in run.fileChanges {
            guard let file = discoveredRunFile(
                path: change.path,
                allowedRoots: allowedRoots,
                fileManager: fileManager
            ) else { continue }
            guard seen.insert(URL(fileURLWithPath: file.path).standardizedFileURL.path).inserted else { continue }
            discovered.append(file)
        }
        let workspaceFiles = TaskOutputWorkspaceDiscovery.filesChangedDuringRun(
            workspacePath: taskAccess.effectiveWorkspacePath,
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
    static func filesAsync(for task: AgentTask, fileManager: FileManager = .default) async -> [TaskOutputDiscoveredFile] {
        await filesAsync(in: TaskWorkspaceAccess(task: task).taskFolder, fileManager: fileManager)
    }

    static func filesAsync(in taskFolder: String, fileManager: FileManager = .default) async -> [TaskOutputDiscoveredFile] {
        await Task.detached(priority: .utility) {
            files(in: taskFolder, fileManager: fileManager)
        }.value
    }

    static func files(in taskFolder: String, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
        guard !taskFolder.isEmpty else { return [] }
        let folderURL = URL(fileURLWithPath: taskFolder)
        let folderPath = folderURL.standardizedFileURL.path
        let resolvedFolderPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard fileManager.fileExists(atPath: folderPath) else { return [] }

        return TaskGeneratedFiles.files(in: folderPath, fileManager: fileManager)
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

    static func filesChanged(during run: TaskRun, from files: [TaskOutputDiscoveredFile]) -> [TaskOutputDiscoveredFile] {
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
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath == taskFolderPath || standardizedPath.hasPrefix(taskFolderPath + "/") else {
            return nil
        }

        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == resolvedTaskFolderPath || resolvedPath.hasPrefix(resolvedTaskFolderPath + "/") else {
            return nil
        }

        let relative = String(standardizedPath.dropFirst(taskFolderPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty,
              TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relative) else {
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

    private static func discoveredRunFile(
        path: String,
        allowedRoots: [String],
        fileManager: FileManager
    ) -> TaskOutputDiscoveredFile? {
        let url = URL(fileURLWithPath: path)
        let standardizedPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        guard let root = allowedRoots.first(where: { root in
            let rootURL = URL(fileURLWithPath: root)
            let standardRoot = rootURL.standardizedFileURL.path
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            return (standardizedPath == standardRoot || standardizedPath.hasPrefix(standardRoot + "/"))
                && (resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/"))
        }) else {
            return nil
        }

        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let relative = String(standardizedPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty,
              TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relative) else {
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
}
