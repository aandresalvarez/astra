import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import ASTRACore

enum TaskDeliverableExpectation {
    static let artifactScanEntryLimit = 500
    static let artifactScanDepthLimit = 4

    static func requiresStandaloneArtifact(_ task: AgentTask) -> Bool {
        let combinedIntent = deliverableIntentText(for: task)
        if outputFilenames(in: combinedIntent) == transientOutputFilenames(in: combinedIntent),
           !transientOutputFilenames(in: combinedIntent).isEmpty {
            return false
        }

        let text = [
            persistentDeliverableText(from: task.title),
            persistentDeliverableText(from: task.goal),
            persistentDeliverableText(from: task.inputs.joined(separator: " ")),
            persistentDeliverableText(from: task.acceptanceCriteria.joined(separator: " "))
        ]
            .joined(separator: " ")
            .lowercased()

        let artifactActionWords: Set<String> = [
            "write", "create", "creat", "cerate", "crefate", "build", "buid", "make", "generate", "save"
        ]
        let artifactActionPhrases = [
            "put this in files", "write this in files"
        ]
        guard TaskIntentLanguagePolicy.containsAffirmativeAction(
            in: text,
            words: artifactActionWords,
            phrases: artifactActionPhrases
        ) || containsJoinedArticleAction(text, Array(artifactActionWords)) else {
            return false
        }

        // Distinctive enough to match anywhere in the text.
        let artifactPhrases = [
            "web page", "webpage", "html", "javascript", "css", ".html", ".js", ".css",
            "demo app", "game", "script", "file", "slide deck", "slides", "presentation", "deck",
            "user interface", "web site", "spreadsheet", "wireframe", "mockup", "prototype",
            "dashboard", "notebook", "readme"
        ]
        // Short nouns have to match as whole words. Substring matching would
        // turn "ui" into a hit for "build", "guide" and "require", and "app"
        // into a hit for "happens" and "appropriate".
        let artifactWords = ["app", "ui", "website", "csv"]

        // The action word above already established that the user asked for
        // something to be produced; this only decides whether the thing is the
        // kind that lands on disk. The vocabulary is precise rather than broad
        // because the two mistakes do not cost the same. Missing an artifact
        // request tightens a watchdog window. Inventing one rewrites the prompt
        // around a file the user never asked for — the first-action contract in
        // `AgentPromptBuilder` — and then blocks completion when that file does
        // not appear. So nouns that name a *shape* of answer as readily as a
        // file — "report", "document", "diagram", a format like "json" or "sql"
        // — stay out, and only nouns that can scarcely be delivered any other
        // way are in.
        return containsAny(text, artifactPhrases) || containsAnyWholeWord(text, artifactWords)
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

    /// Whether `run` owes the deliverable the task's own request names.
    static func owesDeliverable(_ task: AgentTask, run: TaskRun?) -> Bool {
        guard requiresDeliverableArtifact(task) else { return false }
        guard let run else { return true }
        return !followsUpDeliveredRequest(run, in: task)
    }

    /// One task-history row, as live events and transcript snapshots both carry it.
    struct HistoryEvent {
        let type: String
        let runID: UUID?
        let timestamp: Date
        let payload: String
    }

    struct HistoryRun {
        let id: UUID
        let startedAt: Date
        let status: RunStatus
        let stopReason: String
    }

    static func followsUpDeliveredRequest(_ run: TaskRun, in task: AgentTask) -> Bool {
        let relevantTypes = deliveryHistoryEventTypes
        return followsUpDeliveredRequest(
            runID: run.id,
            startedAt: run.startedAt,
            events: task.events.lazy
                .filter { relevantTypes.contains($0.type) }
                .map { HistoryEvent(type: $0.type, runID: $0.run?.id, timestamp: $0.timestamp, payload: $0.payload) },
            runs: task.runs.lazy.map { HistoryRun(id: $0.id, startedAt: $0.startedAt, status: $0.status, stopReason: $0.stopReason) }
        )
    }

    /// The same answer from bounded store reads instead of `task.events` and
    /// `task.runs`, for the review dock, which asks once per snapshot revision
    /// so its answer does not depend on the transcript window:
    /// - the run's own source event (a run has one),
    /// - whether any whole-task approval or finished plan precedes it (one row),
    /// - the most recent earlier completed runs, newest first, stopping at the
    ///   first that an approved-plan request did not start.
    /// The last read looks at most `recentCompletedRunLimit` runs back; a task
    /// whose last that-many completions were all intermediate plan steps reads
    /// as still owing, which is the conservative answer.
    @MainActor
    static func followsUpDeliveredRequest(
        taskID: UUID,
        runID: UUID,
        startedAt: Date,
        in modelContext: ModelContext
    ) throws -> Bool {
        guard try runStartsByConversation(runID, in: modelContext) else { return false }

        let approved = TaskEventTypes.Task.approved.rawValue
        let planFinished = TaskEventTypes.Plan.executionCompleted.rawValue
        let approvalPrefix = userApprovalPayloadPrefix
        var metDescriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate<TaskEvent> {
            $0.task?.id == taskID && $0.timestamp < startedAt
                && ($0.type == planFinished || ($0.type == approved && $0.payload.starts(with: approvalPrefix)))
        })
        metDescriptor.fetchLimit = 1
        if try !modelContext.fetch(metDescriptor).isEmpty { return true }

        let completed = TaskRunStopReason.completed.rawValue
        var runDescriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> {
                $0.task?.id == taskID && $0.startedAt < startedAt && $0.stopReason == completed
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        runDescriptor.fetchLimit = recentCompletedRunLimit
        for earlierRun in try modelContext.fetch(runDescriptor) where earlierRun.status == .completed {
            if try !runStartsAsApprovedPlan(earlierRun.id, in: modelContext) { return true }
        }
        return false
    }

    static let recentCompletedRunLimit = 50

    @MainActor
    private static func runSourceEvents(_ runID: UUID, in modelContext: ModelContext) throws -> [TaskEvent] {
        let target: UUID? = runID
        let sourceTypes = runSourceEventTypes
        var descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate<TaskEvent> {
            $0.run?.id == target && sourceTypes.contains($0.type)
        })
        descriptor.fetchLimit = 4
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    private static func runStartsByConversation(_ runID: UUID, in modelContext: ModelContext) throws -> Bool {
        try runSourceEvents(runID, in: modelContext).contains {
            requestSource(type: $0.type, payload: $0.payload) == .conversation
        }
    }

    @MainActor
    private static func runStartsAsApprovedPlan(_ runID: UUID, in modelContext: ModelContext) throws -> Bool {
        try runSourceEvents(runID, in: modelContext).contains {
            requestSource(type: $0.type, payload: $0.payload) == .approvedPlan
        }
    }

    private static let runSourceEventTypes = [
        TaskEventTypes.Conversation.userMessage.rawValue,
        TaskEventTypes.ExecutionRequest.retry.rawValue,
        TaskEventTypes.ExecutionRequest.resume.rawValue,
        TaskEventTypes.ExecutionRequest.permissionResume.rawValue,
        TaskEventTypes.ExecutionRequest.planStep.rawValue
    ]

    /// Whether `runID` continues the conversation after the task's own request
    /// was already met, and so does not owe that deliverable again — "commit
    /// notes-a.txt" after the run that wrote it.
    ///
    /// Met: an earlier run finished `completed` (runtime success, or every
    /// required outcome published; a blocked run is recorded as failed), the
    /// approved plan finished, or the user approved the whole task. A finished
    /// plan step is not evidence on its own while later steps remain, and a
    /// publication receipt is not a whole-task approval.
    ///
    /// Continues the conversation: the run was started by a user message or by
    /// a resume, retry or permission continuation of one. An approved plan step
    /// carries out the task's own request, so it owes the deliverable however
    /// many steps completed before it.
    static func followsUpDeliveredRequest<Events: Sequence, Runs: Sequence>(
        runID: UUID,
        startedAt: Date,
        events: Events,
        runs: Runs
    ) -> Bool where Events.Element == HistoryEvent, Runs.Element == HistoryRun {
        var startedByConversation = false
        var metEarlier = false
        var planStepRunIDs: Set<UUID> = []
        for event in events {
            if let source = event.runID {
                switch requestSource(type: event.type, payload: event.payload) {
                case .conversation where source == runID: startedByConversation = true
                case .approvedPlan: planStepRunIDs.insert(source)
                default: break
                }
            }
            if event.timestamp < startedAt,
               event.type == TaskEventTypes.Plan.executionCompleted.rawValue
                || (event.type == TaskEventTypes.Task.approved.rawValue && event.payload.hasPrefix(userApprovalPayloadPrefix)) {
                metEarlier = true
            }
        }
        guard startedByConversation else { return false }
        return metEarlier || runs.contains {
            $0.startedAt < startedAt && !planStepRunIDs.contains($0.id)
                && $0.status == .completed && $0.stopReason == TaskRunStopReason.completed.rawValue
        }
    }

    /// `TaskLifecycleCoordinator.approveTask`'s whole-task approval, as opposed
    /// to the runtime-permission approvals and publication receipts that share
    /// the `task.approved` event type.
    static let userApprovalPayloadPrefix = "Task approved by user"

    static let deliveryHistoryEventTypes: Set<String> = [
        TaskEventTypes.Conversation.userMessage.rawValue,
        TaskEventTypes.Task.approved.rawValue,
        TaskEventTypes.Plan.executionCompleted.rawValue,
        TaskEventTypes.ExecutionRequest.planStep.rawValue,
        TaskEventTypes.ExecutionRequest.retry.rawValue,
        TaskEventTypes.ExecutionRequest.resume.rawValue,
        TaskEventTypes.ExecutionRequest.permissionResume.rawValue
    ]

    private enum RequestSource { case conversation, approvedPlan, other }

    /// What started a run, read from its linked source event.
    private static func requestSource(type: String, payload: String) -> RequestSource {
        if type == TaskEventTypes.Conversation.userMessage.rawValue { return .conversation }
        guard [
            TaskEventTypes.ExecutionRequest.retry.rawValue,
            TaskEventTypes.ExecutionRequest.resume.rawValue,
            TaskEventTypes.ExecutionRequest.permissionResume.rawValue,
            TaskEventTypes.ExecutionRequest.planStep.rawValue
        ].contains(type),
            let source = try? JSONDecoder().decode(TaskExecutionSourcePayloadV1.self, from: Data(payload.utf8)) else {
            return .other
        }
        switch source.launchMode {
        case .continuation: return .conversation
        case .approvedPlan: return .approvedPlan
        case .initial: return .other
        }
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
                    filenames.formUnion(persistentOutputFilenames(in: listSegment))
                }
                if lineStatesNamedOutput(line) {
                    filenames.formUnion(persistentOutputFilenames(in: proseOutputSegment(from: line)))
                }
                continue
            }

            if lineStartsDeliverableListContext(line) {
                acceptsDeliverableListItems = true
            } else if lineStartsNonDeliverableListContext(line) || lineLooksLikeSectionHeader(line) {
                acceptsDeliverableListItems = false
            }

            if lineStatesNamedOutput(line) {
                filenames.formUnion(persistentOutputFilenames(in: proseOutputSegment(from: line)))
            }
        }
        return filenames.subtracting(transientOutputFilenames(in: text))
    }

    static func hasArtifact(
        for task: AgentTask,
        run: TaskRun,
        scanEntryLimit: Int = artifactScanEntryLimit,
        scanDepthLimit: Int = artifactScanDepthLimit
    ) -> Bool {
        // Both roots are the same for every path this call classifies, and
        // resolving them costs a task-folder lookup plus a symlink resolution
        // each. Inside the loop that was charged per artifact, against a
        // relationship that reached 13,295 rows in production.
        let roots = ArtifactPathRoots(task: task)

        if run.fileChanges.contains(where: { isUserArtifactPath($0.path, roots: roots) }) {
            return true
        }

        if task.artifacts.contains(where: { !$0.isStale && isUserArtifactPath($0.path, roots: roots) }) {
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
        hasRunScopedArtifact(
            for: task,
            fileChanges: run.fileChanges,
            runStartedAt: run.startedAt,
            runCompletedAt: run.completedAt,
            scanEntryLimit: scanEntryLimit,
            scanDepthLimit: scanDepthLimit
        )
    }

    static func hasRunScopedArtifact(
        for task: AgentTask,
        fileChanges: [StoredFileChange],
        runStartedAt: Date,
        runCompletedAt: Date?,
        scanEntryLimit: Int = artifactScanEntryLimit,
        scanDepthLimit: Int = artifactScanDepthLimit
    ) -> Bool {
        let roots = ArtifactPathRoots(task: task)
        if fileChanges.contains(where: { isUserArtifactPath($0.path, roots: roots) }) {
            return true
        }

        return taskFolderContainsUserArtifact(
            for: task,
            entryLimit: scanEntryLimit,
            depthLimit: scanDepthLimit,
            runStartedAt: runStartedAt,
            runCompletedAt: runCompletedAt
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

    /// `workspacePath` is the code root the deliverables were searched in.
    /// Without one this names where the task's code runs: a pinned worktree,
    /// not the workspace it belongs to.
    static func missingDeliverableMessage(
        for task: AgentTask,
        requiredFilenames: Set<String>,
        workspacePath: String? = nil
    ) -> String {
        guard !requiredFilenames.isEmpty else {
            return missingArtifactMessage(for: task)
        }

        let access = TaskWorkspaceAccess(task: task)
        let searchedRoot = workspacePath ?? access.codeWorkingDirectory
        let rootLabel = searchedRoot.isEmpty || searchedRoot == access.effectiveWorkspacePath
            ? "Workspace root"
            : "Working directory"
        let workspaceLocation = searchedRoot.isEmpty ? "the workspace root" : searchedRoot
        let taskFolderLocation = access.taskFolder.isEmpty ? "the task output folder" : access.taskFolder
        let filenames = requiredFilenames.sorted().joined(separator: ", ")
        let fileNoun = requiredFilenames.count == 1 ? "file" : "files"
        return """
        Missing explicitly requested deliverable \(fileNoun): \(filenames).
        ASTRA did not mark this task complete because this run did not create the requested \(fileNoun).
        Expected deliverable search roots:
        - \(rootLabel): \(workspaceLocation)
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

    /// Removes an explicitly transient file lifecycle from final-deliverable
    /// inference. A named file is transient only when one instruction names a
    /// single file, marks it as temporary/scratch/probe state, and explicitly
    /// requires removing it. Ambiguous or multi-file instructions remain
    /// fail-closed so a cleanup aside cannot erase a real requested output.
    private static func persistentDeliverableText(from rawText: String) -> String {
        deliverableRelevantText(from: rawText)
            .components(separatedBy: .newlines)
            .filter { transientOutputFilenames(in: $0).isEmpty }
            .joined(separator: "\n")
    }

    private static func deliverableIntentText(for task: AgentTask) -> String {
        [
            deliverableRelevantText(from: task.title),
            deliverableRelevantText(from: task.goal),
            deliverableRelevantText(from: task.inputs.joined(separator: "\n")),
            deliverableRelevantText(from: task.acceptanceCriteria.joined(separator: "\n"))
        ].joined(separator: "\n")
    }

    private static func persistentOutputFilenames(in text: String) -> Set<String> {
        outputFilenames(in: text).subtracting(transientOutputFilenames(in: text))
    }

    private static func transientOutputFilenames(in text: String) -> Set<String> {
        let filenames = outputFilenames(in: text)
        guard !filenames.isEmpty else { return [] }

        let clauses = text.lowercased()
            .replacingOccurrences(
                of: #"(?:\r?\n|;|\.\s+|,\s*(?:and\s+(?:then\s+)?)?|\s+and\s+(?:then\s+)?)"#,
                with: "\n",
                options: .regularExpression
            )
            .components(separatedBy: .newlines)
        let transientWords: Set<String> = ["temporary", "temp", "scratch", "probe"]
        let removalWords: Set<String> = ["delete", "discard", "remove"]
        let containsRemovalAction: (String) -> Bool = { clause in
            TaskIntentLanguagePolicy.containsAffirmativeAction(
                in: clause,
                words: removalWords,
                phrases: ["clean up"]
            )
        }

        return Set(filenames.filter { filename in
            let needle = filename.lowercased()
            for index in clauses.indices where clauses[index].contains(needle) {
                let filenameClause = clauses[index]
                let tokens = Set(filenameClause
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init))
                let namedAsTransient = !tokens.isDisjoint(with: transientWords)
                    || transientWords.contains(where: { needle.contains($0) })
                guard namedAsTransient else { continue }

                if containsRemovalAction(filenameClause) { return true }

                // Creation, verification, and cleanup are commonly separate
                // clauses or task fields. Look only forward from the named
                // transient file, stopping before a different output is
                // introduced, so an unrelated cleanup instruction cannot
                // erase a later persistent deliverable.
                for laterIndex in clauses.indices where laterIndex > index {
                    let later = clauses[laterIndex]
                    if filenames.contains(where: {
                        $0.caseInsensitiveCompare(filename) != .orderedSame
                            && later.contains($0.lowercased())
                    }) {
                        break
                    }
                    if containsRemovalAction(later)
                        && (later.contains(needle)
                            || later.range(of: #"\b(it|this file|the file)\b"#, options: .regularExpression) != nil) {
                        return true
                    }
                }
            }
            return false
        })
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

    /// The task-folder and workspace roots every artifact path in one call is
    /// classified against, resolved once.
    ///
    /// Each root costs a `TaskWorkspaceAccess` lookup and a
    /// `resolvingSymlinksInPath` — a `getattrlist` per path component. Building
    /// them per path made run finalize O(artifacts) in symlink resolutions on
    /// the main actor.
    struct ArtifactPathRoots {
        let taskFolder: URL?
        let workspace: URL?

        init(task: AgentTask) {
            let access = TaskWorkspaceAccess(task: task)
            let folder = access.taskFolder
            taskFolder = folder.isEmpty
                ? nil
                : URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL
            let workspacePath = access.effectiveWorkspacePath
            workspace = workspacePath.isEmpty
                ? nil
                : URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().standardizedFileURL
        }
    }

    private static func isUserArtifactPath(_ path: String, roots: ArtifactPathRoots) -> Bool {
        guard let root = roots.taskFolder else { return true }
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        if !normalizedPath.hasPrefix("/"),
           TaskOutputArtifactPathPolicy.isRuntimeDiagnosticRelativePath(normalizedPath, context: .taskFolder) {
            return false
        }
        let url = normalizedPath.hasPrefix("/")
            ? URL(fileURLWithPath: normalizedPath)
            : root.appendingPathComponent(normalizedPath)
        if let relative = relativePath(of: url, resolvedRoot: root) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }

        if let workspaceRoot = roots.workspace,
           let workspaceRelative = relativePath(of: url, resolvedRoot: workspaceRoot) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                workspaceRelative,
                context: .workspace
            ) != nil
        }

        return true
    }

    private static func relativePath(of fileURL: URL, taskFolder: URL) -> String? {
        relativePath(
            of: fileURL,
            resolvedRoot: taskFolder.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    /// `resolvedRoot` has already been through `resolvingSymlinksInPath`, so
    /// the only filesystem work left is resolving the path being classified.
    private static func relativePath(of fileURL: URL, resolvedRoot: URL) -> String? {
        let prefix = resolvedRoot.path + "/"
        let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
