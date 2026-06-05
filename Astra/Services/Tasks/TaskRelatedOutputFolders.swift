import Foundation

enum TaskRelatedOutputFolders {
    private static let taskFolderRegex = try? NSRegularExpression(
        pattern: #"(?:~|/)[^\r\n`"'<>\])}]+/tasks/[A-Za-z0-9][A-Za-z0-9_-]{5,}"#
    )

    static func legacyOutputFolders(
        for task: AgentTask,
        workspace: Workspace?,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let workspace else { return [] }
        var paths: [String] = []
        var seen: Set<String> = []
        let workspacePath = standardizedPath(workspace.primaryPath)
        guard !workspacePath.isEmpty else { return [] }
        let resolvedWorkspacePath = resolvedSymlinkPath(workspacePath)

        func append(_ rawPath: String) {
            let path = standardizedPath(rawPath)
            guard !path.isEmpty else {
                return
            }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  isLegacyTaskFolder(path, workspacePath: workspacePath, resolvedWorkspacePath: resolvedWorkspacePath),
                  seen.insert(path).inserted else {
                return
            }
            paths.append(path)
        }

        append(WorkspaceFileLayout.legacyTaskFolder(workspacePath: workspace.primaryPath, taskID: task.id))

        for text in candidateTexts(for: task) {
            for path in taskFolderPaths(in: text) {
                append(path)
            }
        }

        return paths.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func candidateTexts(for task: AgentTask) -> [String] {
        var texts = [
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " ")
        ]

        for run in task.runs {
            for change in run.fileChanges {
                texts.append(change.path)
            }
        }

        for artifact in task.artifacts {
            texts.append(artifact.path)
        }

        return texts
    }

    private static func taskFolderPaths(in text: String) -> [String] {
        guard !text.isEmpty,
              let taskFolderRegex else {
            return []
        }

        let nsText = text as NSString
        return taskFolderRegex
            .matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    private static func isLegacyTaskFolder(
        _ path: String,
        workspacePath: String,
        resolvedWorkspacePath: String
    ) -> Bool {
        guard path.contains("/tasks/") else { return false }
        guard isPath(path, containedIn: workspacePath) else { return false }
        let resolvedPath = resolvedSymlinkPath(path)
        guard isPath(resolvedPath, containedIn: resolvedWorkspacePath) else { return false }
        return !isInternalTaskStoragePath(path) && !isInternalTaskStoragePath(resolvedPath)
    }

    private static func isInternalTaskStoragePath(_ path: String) -> Bool {
        path.contains("/.astra/tasks/") || path.contains("/.agentflow/tasks/")
    }

    private static func isPath(_ path: String, containedIn parentPath: String) -> Bool {
        !parentPath.isEmpty && (path == parentPath || path.hasPrefix(parentPath + "/"))
    }

    private static func resolvedSymlinkPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func standardizedPath(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
