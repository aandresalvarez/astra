import Foundation

enum TaskDeliverableExpectation {
    static let artifactScanEntryLimit = 500
    static let artifactScanDepthLimit = 4

    static func requiresStandaloneArtifact(_ task: AgentTask) -> Bool {
        let text = [
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " ")
        ]
            .joined(separator: " ")
            .lowercased()

        guard containsAny(text, [
            "write", "create", "build", "make", "generate", "save", "put this in files", "write this in files"
        ]) else {
            return false
        }

        return containsAny(text, [
            "web page", "webpage", "html", "javascript", "css", ".html", ".js", ".css",
            "demo app", "game", "script", "file"
        ])
    }

    static func hasArtifact(
        for task: AgentTask,
        run: TaskRun,
        scanEntryLimit: Int = artifactScanEntryLimit,
        scanDepthLimit: Int = artifactScanDepthLimit
    ) -> Bool {
        if !run.fileChanges.isEmpty {
            return true
        }

        if task.artifacts.contains(where: { !$0.isStale }) {
            return true
        }

        return taskFolderContainsUserArtifact(
            for: task,
            entryLimit: scanEntryLimit,
            depthLimit: scanDepthLimit
        )
    }

    static func missingArtifactMessage(for task: AgentTask) -> String {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let location = taskFolder.isEmpty ? "the task output folder" : taskFolder
        return """
        ASTRA did not mark this task complete because the user asked for a standalone file artifact, but this run did not create a usable file.
        Expected artifact location: \(location)
        Ask the agent to write the artifact into the task output folder, retry with the needed file-write approval, or explicitly choose a workspace path.
        """
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func taskFolderContainsUserArtifact(
        for task: AgentTask,
        entryLimit: Int,
        depthLimit: Int
    ) -> Bool {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return false }
        guard entryLimit > 0, depthLimit >= 0 else { return false }

        let root = URL(fileURLWithPath: folder).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var scannedEntries = 0
        for case let fileURL as URL in enumerator {
            scannedEntries += 1
            guard scannedEntries <= entryLimit else {
                return false
            }

            let depth = relativeDepth(of: fileURL, taskFolder: root)
            if depth > depthLimit {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true, depth >= depthLimit {
                enumerator.skipDescendants()
            }
            guard values?.isRegularFile == true else { continue }
            if isRuntimeHistoryFile(fileURL, taskFolder: root) {
                continue
            }
            return true
        }
        return false
    }

    private static func relativeDepth(of fileURL: URL, taskFolder: URL) -> Int {
        let relative = relativePath(of: fileURL, taskFolder: taskFolder)
        guard !relative.isEmpty else { return 0 }
        return relative.split(separator: "/", omittingEmptySubsequences: true).count - 1
    }

    private static func isRuntimeHistoryFile(_ fileURL: URL, taskFolder: URL) -> Bool {
        let relative = relativePath(of: fileURL, taskFolder: taskFolder)
        if relative == "session_history.md" {
            return true
        }
        if relative.hasPrefix("outputs/turn_"), relative.hasSuffix(".md") {
            return true
        }
        return false
    }

    private static func relativePath(of fileURL: URL, taskFolder: URL) -> String {
        let prefix = taskFolder.standardizedFileURL.path + "/"
        return fileURL.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
    }
}
