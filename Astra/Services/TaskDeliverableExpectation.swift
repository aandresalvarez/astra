import Foundation

enum TaskDeliverableExpectation {
    static let artifactScanEntryLimit = 500
    static let artifactScanDepthLimit = 4

    static func requiresStandaloneArtifact(_ task: AgentTask) -> Bool {
        let text = [
            deliverableRelevantText(from: task.title),
            deliverableRelevantText(from: task.goal),
            deliverableRelevantText(from: task.inputs.joined(separator: " ")),
            deliverableRelevantText(from: task.acceptanceCriteria.joined(separator: " "))
        ]
            .joined(separator: " ")
            .lowercased()

        let artifactActionWords = [
            "write", "create", "creat", "cerate", "build", "make", "generate", "save"
        ]
        let artifactActionPhrases = [
            "put this in files", "write this in files"
        ]
        guard containsAnyWholeWord(text, artifactActionWords) || containsAny(text, artifactActionPhrases) else {
            return false
        }

        return containsAny(text, [
            "web page", "webpage", "html", "javascript", "css", ".html", ".js", ".css",
            "demo app", "game", "script", "file", "slide deck", "slides", "presentation", "deck"
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

    static func hasRunScopedArtifact(
        for task: AgentTask,
        run: TaskRun,
        scanEntryLimit: Int = artifactScanEntryLimit,
        scanDepthLimit: Int = artifactScanDepthLimit
    ) -> Bool {
        if !run.fileChanges.isEmpty {
            return true
        }

        return taskFolderContainsUserArtifact(
            for: task,
            entryLimit: scanEntryLimit,
            depthLimit: scanDepthLimit,
            runStartedAt: run.startedAt,
            runCompletedAt: run.completedAt
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

    private static func containsAnyWholeWord(_ text: String, _ words: [String]) -> Bool {
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return words.contains { tokens.contains($0) }
    }

    private static func deliverableRelevantText(from rawText: String) -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let embeddedGoal = embeddedGoalText(from: text) {
            return embeddedGoal
        }
        return removingRuntimeInstructionLines(from: text)
    }

    private static func embeddedGoalText(from text: String) -> String? {
        let lower = text.lowercased()
        guard containsAny(lower, [
            "task output folder:",
            "current task:",
            "recent tasks in this workspace",
            "context/inputs:",
            "remote server:"
        ]) else {
            return nil
        }

        let lines = text.components(separatedBy: .newlines)
        guard let goalIndex = lines.indices.last(where: { line in
            lines[line]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("goal:")
        }) else {
            return nil
        }

        var goalLines: [String] = []
        let firstLine = lines[goalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let firstGoalText = String(firstLine.dropFirst("Goal:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !firstGoalText.isEmpty {
            goalLines.append(firstGoalText)
        }

        for line in lines.dropFirst(goalIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPromptSectionHeader(trimmed) {
                break
            }
            goalLines.append(line)
        }

        let result = goalLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func removingRuntimeInstructionLines(from text: String) -> String {
        var keptLines: [String] = []
        var skippingTaskOutputBlock = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("task output folder:") {
                skippingTaskOutputBlock = true
                continue
            }

            if skippingTaskOutputBlock {
                if lower.isEmpty {
                    skippingTaskOutputBlock = false
                }
                continue
            }

            if isRuntimeInstructionLine(lower) {
                continue
            }

            keptLines.append(line)
        }

        return keptLines.joined(separator: "\n")
    }

    private static func isPromptSectionHeader(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower == "context/inputs:" ||
            lower == "constraints:" ||
            lower == "acceptance criteria:" ||
            lower.hasPrefix("task output folder:") ||
            lower.hasPrefix("current task reminder:") ||
            lower.hasPrefix("workspace context:") ||
            lower.hasPrefix("behavioral instructions") ||
            lower.hasPrefix("available ssh connections") ||
            lower.hasPrefix("remote server:") ||
            lower.hasPrefix("working directory:") ||
            lower.hasPrefix("additional workspace folders:")
    }

    private static func isRuntimeInstructionLine(_ lowercasedLine: String) -> Bool {
        lowercasedLine.hasPrefix("absolute path:") ||
            lowercasedLine.hasPrefix("this directory already exists.") ||
            lowercasedLine.hasPrefix("save output files, reports, or artifacts there") ||
            lowercasedLine.hasPrefix("save any output files, reports, or artifacts to this folder") ||
            lowercasedLine.hasPrefix("for standalone generated files or artifacts requested by the user") ||
            lowercasedLine.hasPrefix("for informational tasks, summaries, reviews, lookups, and status checks")
    }

    private static func taskFolderContainsUserArtifact(
        for task: AgentTask,
        entryLimit: Int,
        depthLimit: Int,
        runStartedAt: Date? = nil,
        runCompletedAt: Date? = nil
    ) -> Bool {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return false }
        guard entryLimit > 0, depthLimit >= 0 else { return false }

        let root = URL(fileURLWithPath: folder)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey],
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

            guard let relative = relativePath(of: fileURL, taskFolder: root) else { continue }
            let depth = relativeDepth(of: relative)
            if depth > depthLimit {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey]
            )
            if values?.isDirectory == true, depth >= depthLimit {
                enumerator.skipDescendants()
            }
            guard values?.isRegularFile == true else { continue }
            if !TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relative) {
                continue
            }
            if let runStartedAt,
               !fileWasCreatedOrModifiedDuringRun(values, startedAt: runStartedAt, completedAt: runCompletedAt) {
                continue
            }
            return true
        }
        return false
    }

    private static func fileWasCreatedOrModifiedDuringRun(
        _ values: URLResourceValues?,
        startedAt: Date,
        completedAt: Date?
    ) -> Bool {
        let upperBound = completedAt?.addingTimeInterval(1)
        return [values?.creationDate, values?.contentModificationDate].contains { date in
            guard let date, date >= startedAt else { return false }
            if let upperBound {
                return date <= upperBound
            }
            return true
        }
    }

    private static func relativeDepth(of relative: String) -> Int {
        guard !relative.isEmpty else { return 0 }
        return relative.split(separator: "/", omittingEmptySubsequences: true).count - 1
    }

    private static func relativePath(of fileURL: URL, taskFolder: URL) -> String? {
        let prefix = taskFolder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
