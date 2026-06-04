import Foundation

struct TaskOutputDiscoveredFile: Hashable {
    var path: String
    var relativePath: String
    var type: String
    var modifiedAt: Date?
}

enum TaskOutputDiscovery {
    @MainActor
    static func files(for task: AgentTask, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
        files(in: TaskWorkspaceAccess(task: task).taskFolder, fileManager: fileManager)
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
            type: artifactType(for: standardizedPath),
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    private static func artifactType(for path: String) -> String {
        if TaskGeneratedFiles.isHTMLFile(path) { return "html" }
        if TaskGeneratedFiles.isMarkdownFile(path) { return "markdown" }
        if TaskGeneratedFiles.isSQLFile(path) { return "sql" }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext.isEmpty ? "file" : ext
    }
}
