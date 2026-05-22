import Foundation

enum TaskDeliverableExpectation {
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

    static func hasArtifact(for task: AgentTask, run: TaskRun) -> Bool {
        if !run.fileChanges.isEmpty {
            return true
        }

        if task.artifacts.contains(where: { !$0.isStale }) {
            return true
        }

        return taskFolderContainsUserArtifact(for: task)
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

    private static func taskFolderContainsUserArtifact(for task: AgentTask) -> Bool {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return false }

        let root = URL(fileURLWithPath: folder).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            if isRuntimeHistoryFile(fileURL, taskFolder: root) {
                continue
            }
            return true
        }
        return false
    }

    private static func isRuntimeHistoryFile(_ fileURL: URL, taskFolder: URL) -> Bool {
        let relative = fileURL.standardizedFileURL.path
            .replacingOccurrences(of: taskFolder.standardizedFileURL.path + "/", with: "")
        if relative == "session_history.md" {
            return true
        }
        if relative.hasPrefix("outputs/turn_"), relative.hasSuffix(".md") {
            return true
        }
        return false
    }
}
