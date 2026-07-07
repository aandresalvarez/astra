import Foundation
import ASTRAModels
import ASTRAPersistence
import ASTRACore

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
            "write", "create", "creat", "cerate", "crefate", "build", "buid", "make", "generate", "save"
        ]
        let artifactActionPhrases = [
            "put this in files", "write this in files"
        ]
        guard containsAnyWholeWord(text, artifactActionWords)
                || containsJoinedArticleAction(text, artifactActionWords)
                || containsAny(text, artifactActionPhrases) else {
            return false
        }

        return containsAny(text, [
            "web page", "webpage", "html", "javascript", "css", ".html", ".js", ".css",
            "demo app", "game", "script", "file", "slide deck", "slides", "presentation", "deck"
        ])
    }

    static func requiresDeliverableArtifact(_ task: AgentTask) -> Bool {
        requiresDeliverableArtifact(task, requiredOutputFilenames: requiredOutputFilenames(task))
    }

    static func requiresDeliverableArtifact(
        _ task: AgentTask,
        requiredOutputFilenames: Set<String>
    ) -> Bool {
        requiresStandaloneArtifact(task) || !requiredOutputFilenames.isEmpty
    }

    static func requiredOutputFilenames(_ task: AgentTask) -> Set<String> {
        let text = [
            deliverableRelevantText(from: task.title),
            deliverableRelevantText(from: task.goal),
            deliverableRelevantText(from: task.inputs.joined(separator: " ")),
            deliverableRelevantText(from: task.acceptanceCriteria.joined(separator: " "))
        ]
            .joined(separator: "\n")

        var filenames: Set<String> = []
        var acceptsDeliverableListItems = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                acceptsDeliverableListItems = false
                continue
            }

            if let listSegment = explicitDeliverableListSegment(from: line) {
                if acceptsDeliverableListItems {
                    filenames.formUnion(outputFilenames(in: listSegment))
                }
                if lineStatesNamedOutput(line) {
                    filenames.formUnion(outputFilenames(in: proseOutputSegment(from: line)))
                }
                continue
            }

            if lineStartsDeliverableListContext(line) {
                acceptsDeliverableListItems = true
            } else if lineStartsNonDeliverableListContext(line) || lineLooksLikeSectionHeader(line) {
                acceptsDeliverableListItems = false
            }

            if lineStatesNamedOutput(line) {
                filenames.formUnion(outputFilenames(in: proseOutputSegment(from: line)))
            }
        }
        return filenames
    }

    static func hasArtifact(
        for task: AgentTask,
        run: TaskRun,
        scanEntryLimit: Int = artifactScanEntryLimit,
        scanDepthLimit: Int = artifactScanDepthLimit
    ) -> Bool {
        if run.fileChanges.contains(where: { isUserArtifactPath($0.path, task: task) }) {
            return true
        }

        if task.artifacts.contains(where: { !$0.isStale && isUserArtifactPath($0.path, task: task) }) {
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
        if run.fileChanges.contains(where: { isUserArtifactPath($0.path, task: task) }) {
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

    static func missingDeliverableMessage(for task: AgentTask) -> String {
        missingDeliverableMessage(for: task, requiredFilenames: requiredOutputFilenames(task))
    }

    static func missingDeliverableMessage(for task: AgentTask, requiredFilenames: Set<String>) -> String {
        guard !requiredFilenames.isEmpty else {
            return missingArtifactMessage(for: task)
        }

        let access = TaskWorkspaceAccess(task: task)
        let workspaceLocation = access.effectiveWorkspacePath.isEmpty ? "the workspace root" : access.effectiveWorkspacePath
        let taskFolderLocation = access.taskFolder.isEmpty ? "the task output folder" : access.taskFolder
        let filenames = requiredFilenames.sorted().joined(separator: ", ")
        let fileNoun = requiredFilenames.count == 1 ? "file" : "files"
        return """
        Missing explicitly requested deliverable \(fileNoun): \(filenames).
        ASTRA did not mark this task complete because this run did not create the requested \(fileNoun).
        Expected deliverable search roots:
        - Workspace root: \(workspaceLocation)
        - Task output folder: \(taskFolderLocation)
        Ask the agent to write the missing \(fileNoun) to the requested workspace path, retry with the needed file-write approval, or explicitly choose a workspace path.
        """
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsAnyWholeWord(_ text: String, _ words: [String]) -> Bool {
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return words.contains { tokens.contains($0) }
    }

    private static func containsJoinedArticleAction(_ text: String, _ words: [String]) -> Bool {
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let joinedArticleWords = words.flatMap { word in
            ["\(word)a", "\(word)an"]
        }
        return tokens.contains { token in
            joinedArticleWords.contains(String(token))
        }
    }

    private static func explicitDeliverableListSegment(from line: String) -> String? {
        guard let listText = removingListMarker(from: line) else { return nil }
        let delimiters = [":", " - ", " -- "]
        let delimiterIndex = delimiters.compactMap { delimiter in
            listText.range(of: delimiter)?.lowerBound
        }.min()

        let segment: Substring
        if let delimiterIndex {
            segment = listText[..<delimiterIndex]
        } else {
            segment = Substring(listText)
        }

        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removingListMarker(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }

        guard let range = line.range(of: #"^\d+[\.)]\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range.upperBound...])
    }

    private static func lineStartsDeliverableListContext(_ line: String) -> Bool {
        let lower = line.lowercased()
        if containsAnyWholeWord(lower, ["deliverable", "deliverables", "output", "outputs"]) {
            return true
        }

        return matches(lower, pattern: #"\brequired\b.*\b(?:file|files|filename|filenames|artifact|artifacts)\b"#)
            || matches(lower, pattern: #"\b(?:file|files|filename|filenames|artifact|artifacts)\b.*\brequired\b"#)
    }

    private static func lineStartsNonDeliverableListContext(_ line: String) -> Bool {
        let lower = line.lowercased()
        return containsAnyWholeWord(lower, [
            "input", "inputs", "example", "examples", "reference", "references",
            "source", "sources", "dependency", "dependencies", "context"
        ])
    }

    private static func lineLooksLikeSectionHeader(_ line: String) -> Bool {
        line.hasSuffix(":") && line.count <= 120
    }

    private static func lineStatesNamedOutput(_ line: String) -> Bool {
        let lower = line.lowercased()
        return outputActionRange(in: lower) != nil
            || lineStartsDeliverableListContext(line)
            || lower.contains("named ")
            || lower.contains("file named")
    }

    private static func proseOutputSegment(from line: String) -> String {
        let outputSegment: String
        if let actionRange = outputActionRange(in: line) {
            outputSegment = String(line[actionRange.lowerBound...])
        } else {
            outputSegment = line
        }
        return removingInputReferenceSuffix(from: outputSegment)
    }

    private static func outputActionRange(in line: String) -> Range<String.Index>? {
        line.range(
            of: #"(?i)\b(?:write|create|creat|cerate|crefate|build|buid|make|generate|save|produce)\b"#,
            options: .regularExpression
        )
    }

    private static func removingInputReferenceSuffix(from line: String) -> String {
        guard let inputRange = line.range(
            of: #"(?i)\b(?:from|using|based\s+on|derived\s+from|generated\s+from|sourced\s+from|by\s+reading|by\s+running|after\s+running|with\s+input|with\s+source)\b"#,
            options: .regularExpression
        ) else {
            return line
        }

        let prefix = String(line[..<inputRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return outputFilenames(in: prefix).isEmpty ? line : prefix
    }

    private static func outputFilenames(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(?:\./)?([A-Za-z0-9][A-Za-z0-9._-]*\.(?:html|css|js|mjs|cjs|ts|tsx|jsx|py|rb|go|rs|swift|java|kt|json|md|txt|csv|tsv|yaml|yml|xml|pdf|docx|pptx|xlsx))\b"#
        ) else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range]).lowercased()
        })
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
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
        let hostFileAccess = HostFileAccessBroker()
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: root)
        guard let enumerator = hostFileAccess.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            intent: accessIntent
        ) else {
            return false
        }

        var scannedEntries = 0
        for case let fileURL as URL in enumerator {
            guard !hostFileAccess.shouldSkip(fileURL, intent: accessIntent) else {
                enumerator.skipDescendants()
                continue
            }
            scannedEntries += 1
            guard scannedEntries <= entryLimit else {
                return false
            }

            guard let relative = relativePath(of: fileURL, taskFolder: root) else { continue }
            guard !TaskOutputArtifactPathPolicy.isRuntimeDiagnosticRelativePath(relative) else { continue }
            let depth = TaskOutputArtifactPathPolicy.relativeDepth(of: relative)
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

    private static func isUserArtifactPath(_ path: String, task: AgentTask) -> Bool {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return true }
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        if !normalizedPath.hasPrefix("/"),
           TaskOutputArtifactPathPolicy.isRuntimeDiagnosticRelativePath(normalizedPath, context: .taskFolder) {
            return false
        }
        let root = URL(fileURLWithPath: taskFolder)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let url = normalizedPath.hasPrefix("/")
            ? URL(fileURLWithPath: normalizedPath)
            : root.appendingPathComponent(normalizedPath)
        if let relative = relativePath(of: url, taskFolder: root) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }

        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        if !workspacePath.isEmpty {
            let workspaceRoot = URL(fileURLWithPath: workspacePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if let workspaceRelative = relativePath(of: url, taskFolder: workspaceRoot) {
                return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                    workspaceRelative,
                    context: .workspace
                ) != nil
            }
        }

        return true
    }

    private static func relativePath(of fileURL: URL, taskFolder: URL) -> String? {
        let prefix = taskFolder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
