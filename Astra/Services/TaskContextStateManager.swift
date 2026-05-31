import Foundation

enum TaskThreadMode: String, Codable, Sendable, Equatable {
    case exploration
    case planning
    case execution
    case blocked
    case completed
}

struct TaskContextState: Codable, Sendable, Equatable {
    struct Turn: Codable, Sendable, Equatable {
        var turn: Int
        var ask: String
        var summary: String
        var filesChanged: [String]
        var blockers: [String]
        var outputFile: String?
        var runStatus: String
        var completedAt: String?
    }

    struct SourcePointer: Codable, Sendable, Equatable, Hashable {
        var kind: String
        var id: String?
        var path: String?
        var summary: String
    }

    struct ContextFact: Codable, Sendable, Equatable, Hashable {
        var text: String
        var sourcePointers: [SourcePointer]
        var confidence: String
    }

    struct Objective: Codable, Sendable, Equatable {
        var startingRequest: String
        var currentObjective: String
        var approvedGoal: String?
        var sourcePointers: [SourcePointer]
    }

    struct Verification: Codable, Sendable, Equatable {
        var status: String
        var strategy: String
        var command: String?
        var summary: String
        var evidence: [SourcePointer]
        var updatedAt: String?
    }

    struct ChangedFile: Codable, Sendable, Equatable, Hashable {
        var path: String
        var changeType: String
        var sourcePointers: [SourcePointer]
    }

    struct ArtifactReference: Codable, Sendable, Equatable, Hashable {
        var type: String
        var path: String
        var version: Int
        var isStale: Bool
        var sourcePointers: [SourcePointer]
    }

    var schemaVersion: Int
    var mode: TaskThreadMode
    var startingRequest: String
    var currentObjective: String
    var objective: Objective
    var constraints: [ContextFact]
    var acceptanceCriteria: [ContextFact]
    var testCommand: String?
    var decisions: [String]
    var decisionFacts: [ContextFact]
    var rejectedOptions: [String]
    var openQuestions: [String]
    var candidateGoals: [String]
    var approvedGoal: String?
    var blockers: [String]
    var blockerFacts: [ContextFact]
    var filesChanged: [String]
    var changedFiles: [ChangedFile]
    var artifacts: [ArtifactReference]
    var verification: Verification
    var sourcePointers: [SourcePointer]
    var nextLikelyAction: String?
    var turns: [Turn]
    var updatedAt: String
}

enum TaskContextStateManager {
    static let jsonFileName = "current_state.json"
    static let markdownFileName = "current_state.md"

    private static let schemaVersion = 2
    private static let maxTurns = 12
    private static let maxListItems = 20
    private static let maxPromptTurns = 4
    private static let promptBlockCharacterLimit = 6_000

    private struct LegacyTaskContextState: Decodable {
        var schemaVersion: Int
        var mode: TaskThreadMode
        var startingRequest: String
        var currentObjective: String
        var decisions: [String]
        var rejectedOptions: [String]
        var openQuestions: [String]
        var candidateGoals: [String]
        var approvedGoal: String?
        var blockers: [String]
        var filesChanged: [String]
        var nextLikelyAction: String?
        var turns: [TaskContextState.Turn]
        var updatedAt: String
    }

    @MainActor
    static func recordTurn(task: AgentTask, run: TaskRun, message: String) {
        guard let folder = ensureTaskFolder(for: task) else { return }
        var state = load(taskFolder: folder) ?? initialState(for: task)
        updateDerivedFields(&state, task: task, latestRun: run)

        let turn = makeTurn(
            number: nextTurnNumber(in: state, taskFolder: folder),
            message: message,
            run: run,
            task: task,
            taskFolder: folder
        )
        state.turns.append(turn)
        state.turns = Array(state.turns.suffix(maxTurns))
        state.updatedAt = timestamp(Date())
        save(state, taskFolder: folder, taskID: task.id)
    }

    @MainActor
    static func refresh(task: AgentTask) {
        guard let folder = ensureTaskFolder(for: task) else { return }
        var state = load(taskFolder: folder) ?? initialState(for: task)
        updateDerivedFields(&state, task: task, latestRun: latestRun(for: task))
        state.updatedAt = timestamp(Date())
        save(state, taskFolder: folder, taskID: task.id)
    }

    @MainActor
    static func refreshedPromptContext(for task: AgentTask) -> String? {
        refresh(task: task)
        return promptContext(for: task)
    }

    static func load(taskFolder: String) -> TaskContextState? {
        let url = URL(fileURLWithPath: taskFolder).appendingPathComponent(jsonFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(TaskContextState.self, from: data),
           decoded.schemaVersion == schemaVersion {
            return decoded
        }
        guard let legacy = try? decoder.decode(LegacyTaskContextState.self, from: data),
              legacy.schemaVersion == 1 else {
            return nil
        }
        return migrateLegacyState(legacy, taskFolder: taskFolder)
    }

    static func promptContext(for task: AgentTask) -> String? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty, let state = load(taskFolder: folder) else { return nil }

        var lines: [String] = []
        lines.append("Context Capsule v2:")
        lines.append("- Treat this capsule as the authoritative compact task state. Use transcript, history, and output files as supporting evidence when exact prior wording or details are needed.")
        lines.append("Thread Intent:")
        lines.append("- Mode: \(state.mode.rawValue)")
        if !state.objective.startingRequest.isEmpty {
            lines.append("- Starting request: \(boundedInline(state.objective.startingRequest, maxCharacters: 240))")
        }
        if !state.objective.currentObjective.isEmpty {
            lines.append("- Current objective: \(boundedInline(state.objective.currentObjective, maxCharacters: 320))")
        }
        if let approvedGoal = state.objective.approvedGoal, !approvedGoal.isEmpty {
            lines.append("- Approved goal: \(boundedInline(approvedGoal, maxCharacters: 320))")
        }
        appendFactList("Constraints", state.constraints, to: &lines, limit: 6)
        appendFactList("Acceptance criteria", state.acceptanceCriteria, to: &lines, limit: 6)
        if let testCommand = state.testCommand, !testCommand.isEmpty {
            lines.append("- Test command: \(boundedInline(testCommand, maxCharacters: 320))")
        }
        appendFactList("Decisions", state.decisionFacts, to: &lines, limit: 6)
        appendList("Open questions", state.openQuestions, to: &lines, limit: 5)
        appendFactList("Blockers", state.blockerFacts, to: &lines, limit: 5)
        appendChangedFiles(state.changedFiles, to: &lines, limit: 8)
        lines.append("- Verification: \(state.verification.status) via \(state.verification.strategy) - \(boundedInline(state.verification.summary, maxCharacters: 320))")
        if let command = state.verification.command, !command.isEmpty {
            lines.append("  - Verification command: \(boundedInline(command, maxCharacters: 320))")
        }
        appendSourcePointerList("Verification evidence", state.verification.evidence, to: &lines, limit: 4)
        appendArtifactReferences(state.artifacts, to: &lines, limit: 6)
        if let next = state.nextLikelyAction, !next.isEmpty {
            lines.append("- Next likely action: \(boundedInline(next, maxCharacters: 320))")
        }

        let recentTurns = state.turns.suffix(maxPromptTurns)
        if !recentTurns.isEmpty {
            lines.append("- Recent state turns:")
            for turn in recentTurns {
                let output = turn.outputFile.map { " output: \($0)" } ?? ""
                lines.append("  - Turn \(turn.turn): \(boundedInline(turn.summary, maxCharacters: 260))\(output)")
            }
        }

        lines.append("- Canonical state file: \(folder)/\(jsonFileName)")
        lines.append("- Read \(folder)/\(markdownFileName) or referenced turn outputs if this follow-up depends on older decisions, failures, changed files, or exact prior wording.")

        let block = lines.joined(separator: "\n")
        return block.count > promptBlockCharacterLimit
            ? String(block.prefix(promptBlockCharacterLimit)) + "\n... (thread intent truncated)"
            : block
    }

    static func promptDiagnosticsFields(task: AgentTask, prompt: String, phase: String) -> [String: String] {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let historyPath = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent("session_history.md")
        let outputDirectory = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent("outputs")
        let stateJSONPath = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent(jsonFileName)
        let stateMDPath = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent(markdownFileName)
        let outputFiles = outputTurnFiles(in: outputDirectory)
        let latestOutputChars = outputFiles.last.map(fileSize) ?? 0

        return [
            "phase": phase,
            "prompt_chars": String(prompt.count),
            "estimated_prompt_tokens": String(max(1, prompt.count / 4)),
            "has_context_capsule": String(prompt.contains("Context Capsule v2:")),
            "has_thread_intent": String(prompt.contains("Thread Intent:")),
            "task_folder_present": String(!folder.isEmpty),
            "state_json_chars": String(fileSize(stateJSONPath)),
            "state_md_chars": String(fileSize(stateMDPath)),
            "session_history_chars": String(fileSize(historyPath)),
            "output_file_count": String(outputFiles.count),
            "output_latest_chars": String(latestOutputChars)
        ]
    }

    static func renderMarkdown(_ state: TaskContextState) -> String {
        var parts: [String] = []
        parts.append("# Current State")
        parts.append("")
        parts.append("- Mode: \(state.mode.rawValue)")
        parts.append("- Updated: \(state.updatedAt)")
        if !state.startingRequest.isEmpty {
            parts.append("- Starting request: \(state.startingRequest)")
        }
        if !state.currentObjective.isEmpty {
            parts.append("- Current objective: \(state.currentObjective)")
        }
        if let approvedGoal = state.approvedGoal, !approvedGoal.isEmpty {
            parts.append("- Approved goal: \(approvedGoal)")
        }
        appendMarkdownFacts("Constraints", state.constraints, to: &parts)
        appendMarkdownFacts("Acceptance Criteria", state.acceptanceCriteria, to: &parts)
        if let testCommand = state.testCommand, !testCommand.isEmpty {
            parts.append("")
            parts.append("## Test Command")
            parts.append("`\(testCommand)`")
        }
        appendMarkdownSection("Decisions", state.decisions, to: &parts)
        appendMarkdownFacts("Decision Facts", state.decisionFacts, to: &parts)
        appendMarkdownSection("Rejected options", state.rejectedOptions, to: &parts)
        appendMarkdownSection("Open questions", state.openQuestions, to: &parts)
        appendMarkdownSection("Candidate goals", state.candidateGoals, to: &parts)
        appendMarkdownSection("Blockers", state.blockers, to: &parts)
        appendMarkdownFacts("Blocker Facts", state.blockerFacts, to: &parts)
        appendMarkdownSection("Files changed", state.filesChanged, to: &parts)
        appendMarkdownChangedFiles(state.changedFiles, to: &parts)
        appendMarkdownVerification(state.verification, to: &parts)
        appendMarkdownArtifacts(state.artifacts, to: &parts)
        if let next = state.nextLikelyAction, !next.isEmpty {
            parts.append("")
            parts.append("## Next Likely Action")
            parts.append(next)
        }
        if !state.turns.isEmpty {
            parts.append("")
            parts.append("## Recent Turns")
            for turn in state.turns {
                parts.append("")
                parts.append("### Turn \(turn.turn)")
                parts.append("- Ask: \(turn.ask)")
                parts.append("- Summary: \(turn.summary)")
                parts.append("- Status: \(turn.runStatus)")
                if let completedAt = turn.completedAt {
                    parts.append("- Completed: \(completedAt)")
                }
                if let outputFile = turn.outputFile {
                    parts.append("- Output: \(outputFile)")
                }
                appendMarkdownList(label: "Files", turn.filesChanged, to: &parts)
                appendMarkdownList(label: "Blockers", turn.blockers, to: &parts)
            }
        }
        parts.append("")
        parts.append("> Generated from `\(jsonFileName)`. Edit the JSON source of truth if ASTRA later supports manual state edits.")
        return parts.joined(separator: "\n")
    }

    @MainActor
    private static func initialState(for task: AgentTask) -> TaskContextState {
        TaskContextState(
            schemaVersion: schemaVersion,
            mode: .exploration,
            startingRequest: task.goal,
            currentObjective: task.goal,
            objective: TaskContextState.Objective(
                startingRequest: task.goal,
                currentObjective: task.goal,
                approvedGoal: nil,
                sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task goal")]
            ),
            constraints: task.constraints.map { contextFact($0, sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task constraint")]) },
            acceptanceCriteria: task.acceptanceCriteria.map { contextFact($0, sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task acceptance criterion")]) },
            testCommand: normalizedTestCommand(task),
            decisions: [],
            decisionFacts: [],
            rejectedOptions: [],
            openQuestions: [],
            candidateGoals: [],
            approvedGoal: nil,
            blockers: [],
            blockerFacts: [],
            filesChanged: [],
            changedFiles: [],
            artifacts: [],
            verification: verificationState(task: task, latestRun: nil),
            sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task context")],
            nextLikelyAction: nil,
            turns: [],
            updatedAt: timestamp(Date())
        )
    }

    @MainActor
    private static func updateDerivedFields(_ state: inout TaskContextState, task: AgentTask, latestRun: TaskRun?) {
        let planState = TaskPlanService.reconstruct(for: task)
        state.mode = inferredMode(task: task, planState: planState, latestRun: latestRun)
        state.startingRequest = firstNonEmpty(
            firstConversationRequest(for: task),
            state.startingRequest,
            task.goal
        )
        state.currentObjective = firstNonEmpty(
            planState.plan?.goal,
            state.approvedGoal,
            task.goal,
            state.startingRequest
        )

        if let plan = planState.plan {
            switch planState.lifecycleStatus {
            case .approved, .executing, .completed:
                state.approvedGoal = plan.goal
                state.decisions = dedupeKeepingOrder(state.decisions + ["Approved goal: \(plan.goal)"], limit: maxListItems)
                state.candidateGoals = state.candidateGoals.filter { $0 != plan.goal }
            case .draft:
                state.candidateGoals = dedupeKeepingOrder(state.candidateGoals + [plan.goal], limit: 8)
            case .none, .failed, .cancelled:
                break
            }
        }

        let planBlockers = planState.plan?.steps.compactMap { step -> String? in
            guard step.status == .blocked else { return nil }
            let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Blocked step: \(step.title)" : "Blocked step: \(step.title) - \(detail)"
        } ?? []
        let eventBlockers = task.events
            .filter { ["error", "permission.denied", "permission.approval.requested", "budget.exceeded"].contains($0.type) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
            .map { boundedInline($0.payload, maxCharacters: 220) }
        state.blockers = dedupeKeepingOrder(planBlockers + Array(eventBlockers) + state.blockers, limit: maxListItems)
        if state.mode != .blocked {
            state.blockers = state.blockers.filter { !$0.isEmpty }.prefixArray(maxListItems)
        }

        let changedFiles = task.runs
            .sorted { $0.startedAt < $1.startedAt }
            .flatMap(\.fileChanges)
            .map(\.path)
        state.filesChanged = dedupeKeepingOrder(state.filesChanged + changedFiles, limit: 50)
        state.openQuestions = dedupeKeepingOrder(state.openQuestions + recentQuestions(for: task), limit: 10)
        state.nextLikelyAction = nextLikelyAction(task: task, planState: planState)
        state.objective = objectiveState(task: task, planState: planState, state: state)
        state.constraints = task.constraints.map {
            contextFact($0, sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task constraint")])
        }
        state.acceptanceCriteria = task.acceptanceCriteria.map {
            contextFact($0, sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task acceptance criterion")])
        }
        state.testCommand = normalizedTestCommand(task)
        state.decisionFacts = decisionFacts(for: state, task: task, planState: planState)
        state.blockerFacts = blockerFacts(for: task, planBlockers: planBlockers)
        state.changedFiles = changedFileReferences(for: task)
        state.artifacts = artifactReferences(for: task)
        state.verification = verificationState(task: task, latestRun: latestRun)
        state.sourcePointers = sourcePointers(for: task, state: state)
    }

    private static func save(_ state: TaskContextState, taskFolder: String, taskID: UUID?) {
        do {
            try FileManager.default.createDirectory(atPath: taskFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: URL(fileURLWithPath: taskFolder).appendingPathComponent(jsonFileName), options: .atomic)
            try renderMarkdown(state).write(
                to: URL(fileURLWithPath: taskFolder).appendingPathComponent(markdownFileName),
                atomically: true,
                encoding: .utf8
            )
            if let taskID {
                AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: taskID, fields: [
                    "mode": state.mode.rawValue,
                    "turn_count": String(state.turns.count),
                    "decision_count": String(state.decisions.count),
                    "blocker_count": String(state.blockers.count),
                    "file_count": String(state.filesChanged.count)
                ], level: .debug)
            }
        } catch {
            if let taskID {
                AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: taskID, fields: [
                    "result": "failed",
                    "error": error.localizedDescription
                ], level: .warning)
            }
        }
    }

    private static func migrateLegacyState(_ legacy: LegacyTaskContextState, taskFolder: String) -> TaskContextState {
        let jsonPath = (taskFolder as NSString).appendingPathComponent(jsonFileName)
        let markdownPath = (taskFolder as NSString).appendingPathComponent(markdownFileName)
        let legacySource = sourcePointer(
            kind: "state_file",
            path: jsonPath,
            summary: "Migrated Context Capsule v1"
        )
        let markdownSource = sourcePointer(
            kind: "state_file",
            path: markdownPath,
            summary: "Context Capsule Markdown"
        )
        let currentObjective = firstNonEmpty(legacy.currentObjective, legacy.approvedGoal, legacy.startingRequest)
        let objective = TaskContextState.Objective(
            startingRequest: legacy.startingRequest,
            currentObjective: currentObjective,
            approvedGoal: legacy.approvedGoal,
            sourcePointers: [legacySource]
        )
        let decisionFacts = legacy.decisions.map {
            contextFact($0, sourcePointers: [legacySource], confidence: "migrated")
        }
        let blockerFacts = legacy.blockers.map {
            contextFact($0, sourcePointers: [legacySource], confidence: "migrated")
        }
        let changedFiles = legacy.filesChanged.map {
            TaskContextState.ChangedFile(
                path: $0,
                changeType: "unknown",
                sourcePointers: [legacySource]
            )
        }
        let verification = TaskContextState.Verification(
            status: legacy.mode == .completed ? "unknown" : "not_verified",
            strategy: "unknown",
            command: nil,
            summary: "Migrated from Context Capsule v1; no structured verification evidence was recorded.",
            evidence: [legacySource],
            updatedAt: legacy.updatedAt.isEmpty ? nil : legacy.updatedAt
        )
        let sourcePointers = dedupeSourcePointers(
            [legacySource, markdownSource]
                + objective.sourcePointers
                + decisionFacts.flatMap(\.sourcePointers)
                + blockerFacts.flatMap(\.sourcePointers)
                + changedFiles.flatMap(\.sourcePointers)
                + verification.evidence
        )

        return TaskContextState(
            schemaVersion: schemaVersion,
            mode: legacy.mode,
            startingRequest: legacy.startingRequest,
            currentObjective: currentObjective,
            objective: objective,
            constraints: [],
            acceptanceCriteria: [],
            testCommand: nil,
            decisions: legacy.decisions,
            decisionFacts: decisionFacts,
            rejectedOptions: legacy.rejectedOptions,
            openQuestions: legacy.openQuestions,
            candidateGoals: legacy.candidateGoals,
            approvedGoal: legacy.approvedGoal,
            blockers: legacy.blockers,
            blockerFacts: blockerFacts,
            filesChanged: legacy.filesChanged,
            changedFiles: changedFiles,
            artifacts: [],
            verification: verification,
            sourcePointers: sourcePointers,
            nextLikelyAction: legacy.nextLikelyAction,
            turns: legacy.turns,
            updatedAt: legacy.updatedAt
        )
    }

    @MainActor
    private static func ensureTaskFolder(for task: AgentTask) -> String? {
        let folder = (try? TaskWorkspaceAccess(task: task).ensureTaskFolder()) ?? ""
        return folder.isEmpty ? nil : folder
    }

    private static func makeTurn(
        number: Int,
        message: String,
        run: TaskRun,
        task: AgentTask,
        taskFolder: String
    ) -> TaskContextState.Turn {
        let runBlockers = task.events
            .filter { $0.run?.id == run.id }
            .filter { ["error", "permission.denied", "permission.approval.requested", "budget.exceeded"].contains($0.type) }
            .map { boundedInline($0.payload, maxCharacters: 220) }
        return TaskContextState.Turn(
            turn: number,
            ask: boundedInline(message, maxCharacters: 400),
            summary: summarizeOutput(run.output, fallback: run.stopReason),
            filesChanged: dedupeKeepingOrder(run.fileChanges.map(\.path), limit: 20),
            blockers: dedupeKeepingOrder(runBlockers, limit: 8),
            outputFile: formattedOutputFileName(turn: number),
            runStatus: run.status.rawValue,
            completedAt: run.completedAt.map(timestamp)
        )
    }

    @MainActor
    private static func objectiveState(
        task: AgentTask,
        planState: TaskPlanState,
        state: TaskContextState
    ) -> TaskContextState.Objective {
        var sources = [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task goal")]
        if let firstEvent = firstConversationEvent(for: task) {
            sources.append(eventSource(firstEvent, summary: "First user request"))
        }
        if let plan = planState.plan {
            sources.append(sourcePointer(kind: "plan", id: plan.planID.uuidString, summary: "Task plan goal"))
        }
        return TaskContextState.Objective(
            startingRequest: state.startingRequest,
            currentObjective: state.currentObjective,
            approvedGoal: state.approvedGoal,
            sourcePointers: sources
        )
    }

    @MainActor
    private static func decisionFacts(
        for state: TaskContextState,
        task: AgentTask,
        planState: TaskPlanState
    ) -> [TaskContextState.ContextFact] {
        let planSource = planState.plan.map {
            sourcePointer(kind: "plan", id: $0.planID.uuidString, summary: "Plan lifecycle")
        }
        return state.decisions.map { decision in
            contextFact(
                decision,
                sourcePointers: [planSource ?? sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task decision")]
            )
        }
    }

    @MainActor
    private static func blockerFacts(
        for task: AgentTask,
        planBlockers: [String]
    ) -> [TaskContextState.ContextFact] {
        var facts = planBlockers.map {
            contextFact($0, sourcePointers: [sourcePointer(kind: "plan", id: nil, summary: "Blocked plan step")])
        }
        let eventFacts = task.events
            .filter { ["error", "permission.denied", "permission.approval.requested", "budget.exceeded"].contains($0.type) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
            .map { event in
                contextFact(
                    boundedInline(event.payload, maxCharacters: 220),
                    sourcePointers: [eventSource(event, summary: "Blocking event \(event.type)")]
                )
            }
        facts.append(contentsOf: eventFacts)
        return dedupeFacts(facts, limit: maxListItems)
    }

    @MainActor
    private static func changedFileReferences(for task: AgentTask) -> [TaskContextState.ChangedFile] {
        let sortedRuns = task.runs.sorted { $0.startedAt < $1.startedAt }
        var output: [TaskContextState.ChangedFile] = []
        var indexByPath: [String: Int] = [:]

        for run in sortedRuns {
            for change in run.fileChanges {
                let pointers = [
                    sourcePointer(kind: "run", id: run.id.uuidString, summary: "Provider run"),
                    sourcePointer(kind: "file_change", id: change.id.uuidString, path: change.path, summary: "\(change.changeType) file change")
                ]
                if let index = indexByPath[change.path] {
                    output[index].changeType = change.changeType
                    output[index].sourcePointers = dedupeSourcePointers(output[index].sourcePointers + pointers)
                } else {
                    indexByPath[change.path] = output.count
                    output.append(TaskContextState.ChangedFile(
                        path: change.path,
                        changeType: change.changeType,
                        sourcePointers: pointers
                    ))
                }
            }
        }
        return Array(output.suffix(50))
    }

    @MainActor
    private static func artifactReferences(for task: AgentTask) -> [TaskContextState.ArtifactReference] {
        task.artifacts
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(30)
            .map { artifact in
                TaskContextState.ArtifactReference(
                    type: artifact.type,
                    path: artifact.path,
                    version: artifact.version,
                    isStale: artifact.isStale,
                    sourcePointers: [
                        sourcePointer(kind: "artifact", id: artifact.id.uuidString, path: artifact.path, summary: "Generated artifact")
                    ]
                )
            }
    }

    @MainActor
    private static func verificationState(task: AgentTask, latestRun: TaskRun?) -> TaskContextState.Verification {
        let command = normalizedTestCommand(task)
        let latestValidation = task.events
            .filter(isValidationEvent)
            .sorted { $0.timestamp > $1.timestamp }
            .first

        if let event = latestValidation {
            let status = verificationStatus(for: event)
            return TaskContextState.Verification(
                status: status,
                strategy: task.validationStrategy.rawValue,
                command: command,
                summary: boundedInline(event.payload, maxCharacters: 500),
                evidence: [eventSource(event, summary: "Validation event")],
                updatedAt: timestamp(event.timestamp)
            )
        }

        if task.validationStrategy == .manual, task.status == .completed {
            return TaskContextState.Verification(
                status: "manual_completion",
                strategy: task.validationStrategy.rawValue,
                command: command,
                summary: "Manual completion recorded; no automated verification evidence.",
                evidence: latestRun.map { [sourcePointer(kind: "run", id: $0.id.uuidString, summary: "Completed run")] } ?? [],
                updatedAt: latestRun?.completedAt.map(timestamp)
            )
        }

        if let latestRun, latestRun.status == .failed || latestRun.status == .timeout || latestRun.status == .budgetExceeded {
            return TaskContextState.Verification(
                status: latestRun.status.rawValue,
                strategy: task.validationStrategy.rawValue,
                command: command,
                summary: firstNonEmpty(latestRun.stopReason, "Latest run did not complete successfully."),
                evidence: [sourcePointer(kind: "run", id: latestRun.id.uuidString, summary: "Latest unsuccessful run")],
                updatedAt: latestRun.completedAt.map(timestamp)
            )
        }

        return TaskContextState.Verification(
            status: "not_verified",
            strategy: task.validationStrategy.rawValue,
            command: command,
            summary: "No structured verification result has been recorded yet.",
            evidence: [],
            updatedAt: nil
        )
    }

    @MainActor
    private static func sourcePointers(for task: AgentTask, state: TaskContextState) -> [TaskContextState.SourcePointer] {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        var pointers = [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task source")]
        if !folder.isEmpty {
            pointers.append(sourcePointer(
                kind: "state_file",
                id: nil,
                path: (folder as NSString).appendingPathComponent(jsonFileName),
                summary: "Context Capsule JSON"
            ))
            pointers.append(sourcePointer(
                kind: "state_file",
                id: nil,
                path: (folder as NSString).appendingPathComponent(markdownFileName),
                summary: "Context Capsule Markdown"
            ))
        }
        pointers += state.objective.sourcePointers
        pointers += state.verification.evidence
        pointers += state.decisionFacts.flatMap(\.sourcePointers)
        pointers += state.blockerFacts.flatMap(\.sourcePointers)
        pointers += state.changedFiles.flatMap(\.sourcePointers)
        pointers += state.artifacts.flatMap(\.sourcePointers)
        return dedupeSourcePointers(pointers)
    }

    @MainActor
    private static func latestRun(for task: AgentTask) -> TaskRun? {
        task.runs.max { $0.startedAt < $1.startedAt }
    }

    @MainActor
    private static func firstConversationRequest(for task: AgentTask) -> String? {
        firstConversationEvent(for: task)?
            .payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private static func firstConversationEvent(for task: AgentTask) -> TaskEvent? {
        task.events
            .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
            .sorted { $0.timestamp < $1.timestamp }
            .first
    }

    @MainActor
    private static func recentQuestions(for task: AgentTask) -> [String] {
        task.events
            .filter { $0.type == TaskPlanConversationEventTypes.assistantMessage || $0.type == "agent.response" }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
            .flatMap { questionSentences(in: $0.payload) }
    }

    private static func inferredMode(
        task: AgentTask,
        planState: TaskPlanState,
        latestRun: TaskRun?
    ) -> TaskThreadMode {
        if task.status == .pendingUser ||
            task.status == .failed ||
            task.status == .budgetExceeded ||
            latestRun?.status == .failed ||
            latestRun?.status == .timeout ||
            latestRun?.status == .budgetExceeded {
            return .blocked
        }

        switch planState.lifecycleStatus {
        case .draft, .approved:
            return .planning
        case .executing:
            return .execution
        case .completed:
            return .completed
        case .failed:
            return .blocked
        case .cancelled:
            return .exploration
        case .none:
            break
        }

        if task.status == .completed {
            return .completed
        }
        if task.runs.isEmpty {
            return .exploration
        }
        return .execution
    }

    private static func nextLikelyAction(task: AgentTask, planState: TaskPlanState) -> String? {
        if let plan = planState.plan,
           let nextStep = TaskPlanService.nextExecutableStep(in: plan) {
            return "Continue with plan step: \(nextStep.title)"
        }
        switch task.status {
        case .pendingUser, .failed, .budgetExceeded:
            return "Resolve the blocker or ask ASTRA to continue with more specific instructions."
        case .completed:
            return "Review the result, approve it, or ask a follow-up."
        case .queued, .running:
            return "Continue the current run."
        case .draft:
            return "Define or approve the goal before execution."
        case .cancelled:
            return "Decide whether to retry, revise, or abandon the thread."
        }
    }

    private static func summarizeOutput(_ output: String, fallback: String) -> String {
        let visible = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = visible.isEmpty ? fallback : visible
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No assistant output captured."
        }
        let prefix = String(source.prefix(700))
        if source.count <= 700 {
            return boundedInline(prefix, maxCharacters: 700)
        }
        if let lastPeriod = prefix.lastIndex(of: ".") {
            return boundedInline(String(prefix[prefix.startIndex...lastPeriod]), maxCharacters: 700)
        }
        return boundedInline(prefix, maxCharacters: 700) + "..."
    }

    private static func questionSentences(in text: String) -> [String] {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("?") }
            .map { boundedInline($0, maxCharacters: 220) }
    }

    private static func latestOutputFile(in taskFolder: String) -> String? {
        let outputDirectory = URL(fileURLWithPath: taskFolder).appendingPathComponent("outputs", isDirectory: true)
        let latest = outputTurnFiles(in: outputDirectory.path)
            .last
        return latest.map { "outputs/\(($0 as NSString).lastPathComponent)" }
    }

    private static func outputTurnFiles(in outputDirectory: String) -> [String] {
        guard !outputDirectory.isEmpty,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: outputDirectory),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("turn_") && $0.lastPathComponent.hasSuffix(".md") }
            .map(\.path)
            .sorted()
    }

    private static func fileSize(_ path: String) -> Int {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    private static func nextTurnNumber(in state: TaskContextState, taskFolder: String) -> Int {
        let nextStateTurn = (state.turns.map(\.turn).max() ?? 0) + 1
        if let latest = latestOutputFile(in: taskFolder),
           let parsed = parseTurnNumber(fromOutputFile: latest) {
            return max(parsed, nextStateTurn)
        }
        return nextStateTurn
    }

    private static func parseTurnNumber(fromOutputFile path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("turn_"), name.hasSuffix(".md") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "turn_".count)
        let end = name.index(name.endIndex, offsetBy: -".md".count)
        return Int(name[start..<end])
    }

    private static func formattedOutputFileName(turn: Int) -> String {
        "outputs/turn_\(String(format: "%03d", turn)).md"
    }

    private static func sourcePointer(
        kind: String,
        id: String? = nil,
        path: String? = nil,
        summary: String
    ) -> TaskContextState.SourcePointer {
        TaskContextState.SourcePointer(
            kind: kind,
            id: id,
            path: path,
            summary: boundedInline(summary, maxCharacters: 220)
        )
    }

    private static func eventSource(_ event: TaskEvent, summary: String) -> TaskContextState.SourcePointer {
        sourcePointer(kind: "event", id: event.id.uuidString, summary: summary)
    }

    private static func contextFact(
        _ text: String,
        sourcePointers: [TaskContextState.SourcePointer],
        confidence: String = "derived"
    ) -> TaskContextState.ContextFact {
        TaskContextState.ContextFact(
            text: boundedInline(text, maxCharacters: 700),
            sourcePointers: dedupeSourcePointers(sourcePointers),
            confidence: confidence
        )
    }

    private static func normalizedTestCommand(_ task: AgentTask) -> String? {
        let command = task.testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    private static func isValidationEvent(_ event: TaskEvent) -> Bool {
        let payload = event.payload.lowercased()
        if event.type == "task.completed" {
            return payload.contains("tests passed") || payload.contains("ai check passed")
        }
        guard event.type == "error" else { return false }
        return payload.contains("tests failed")
            || payload.contains("validation error")
            || payload.contains("ai check flagged")
            || payload.contains("ai check error")
    }

    private static func verificationStatus(for event: TaskEvent) -> String {
        let payload = event.payload.lowercased()
        if event.type == "task.completed" {
            return "passed"
        }
        if payload.contains("validation error") || payload.contains("ai check error") {
            return "error"
        }
        return "failed"
    }

    private static func appendList(_ label: String, _ values: [String], to lines: inout [String], limit: Int) {
        let items = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(limit)
        guard !items.isEmpty else { return }
        lines.append("- \(label):")
        for value in items {
            lines.append("  - \(boundedInline(value, maxCharacters: 280))")
        }
    }

    private static func appendFactList(
        _ label: String,
        _ values: [TaskContextState.ContextFact],
        to lines: inout [String],
        limit: Int
    ) {
        let items = values.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(limit)
        guard !items.isEmpty else { return }
        lines.append("- \(label):")
        for value in items {
            let source = value.sourcePointers.first.map { " [source: \(sourceSummary($0))]" } ?? ""
            lines.append("  - \(boundedInline(value.text, maxCharacters: 280))\(source)")
        }
    }

    private static func appendChangedFiles(
        _ values: [TaskContextState.ChangedFile],
        to lines: inout [String],
        limit: Int
    ) {
        let items = values.filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(limit)
        guard !items.isEmpty else { return }
        lines.append("- Files changed:")
        for value in items {
            lines.append("  - \(value.changeType): \(boundedInline(value.path, maxCharacters: 280))")
        }
    }

    private static func appendArtifactReferences(
        _ values: [TaskContextState.ArtifactReference],
        to lines: inout [String],
        limit: Int
    ) {
        let items = values.filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(limit)
        guard !items.isEmpty else { return }
        lines.append("- Artifacts:")
        for value in items {
            let stale = value.isStale ? " stale" : ""
            lines.append("  - \(value.type) v\(value.version)\(stale): \(boundedInline(value.path, maxCharacters: 280))")
        }
    }

    private static func appendSourcePointerList(
        _ label: String,
        _ values: [TaskContextState.SourcePointer],
        to lines: inout [String],
        limit: Int
    ) {
        let items = values.prefix(limit)
        guard !items.isEmpty else { return }
        lines.append("  - \(label):")
        for source in items {
            lines.append("    - \(sourceSummary(source))")
        }
    }

    private static func appendMarkdownSection(_ title: String, _ values: [String], to parts: inout [String]) {
        guard !values.isEmpty else { return }
        parts.append("")
        parts.append("## \(title)")
        for value in values {
            parts.append("- \(value)")
        }
    }

    private static func appendMarkdownFacts(
        _ title: String,
        _ values: [TaskContextState.ContextFact],
        to parts: inout [String]
    ) {
        guard !values.isEmpty else { return }
        parts.append("")
        parts.append("## \(title)")
        for value in values {
            parts.append("- \(value.text)")
            appendMarkdownSources(value.sourcePointers, to: &parts)
        }
    }

    private static func appendMarkdownChangedFiles(
        _ values: [TaskContextState.ChangedFile],
        to parts: inout [String]
    ) {
        guard !values.isEmpty else { return }
        parts.append("")
        parts.append("## Changed File Facts")
        for value in values {
            parts.append("- \(value.changeType): `\(value.path)`")
            appendMarkdownSources(value.sourcePointers, to: &parts)
        }
    }

    private static func appendMarkdownVerification(
        _ verification: TaskContextState.Verification,
        to parts: inout [String]
    ) {
        parts.append("")
        parts.append("## Verification")
        parts.append("- Status: \(verification.status)")
        parts.append("- Strategy: \(verification.strategy)")
        if let command = verification.command, !command.isEmpty {
            parts.append("- Command: `\(command)`")
        }
        parts.append("- Summary: \(verification.summary)")
        if let updatedAt = verification.updatedAt {
            parts.append("- Updated: \(updatedAt)")
        }
        appendMarkdownSources(verification.evidence, to: &parts)
    }

    private static func appendMarkdownArtifacts(
        _ values: [TaskContextState.ArtifactReference],
        to parts: inout [String]
    ) {
        guard !values.isEmpty else { return }
        parts.append("")
        parts.append("## Artifacts")
        for value in values {
            let stale = value.isStale ? " stale" : ""
            parts.append("- \(value.type) v\(value.version)\(stale): `\(value.path)`")
            appendMarkdownSources(value.sourcePointers, to: &parts)
        }
    }

    private static func appendMarkdownSources(
        _ values: [TaskContextState.SourcePointer],
        to parts: inout [String]
    ) {
        guard !values.isEmpty else { return }
        for source in values.prefix(3) {
            parts.append("  - Source: \(sourceSummary(source))")
        }
    }

    private static func appendMarkdownList(label: String, _ values: [String], to parts: inout [String]) {
        guard !values.isEmpty else { return }
        parts.append("- \(label):")
        for value in values {
            parts.append("  - \(value)")
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private static func boundedInline(_ value: String, maxCharacters: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "..."
    }

    private static func dedupeKeepingOrder(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(trimmed)
            if output.count >= limit { break }
        }
        return output
    }

    private static func dedupeFacts(
        _ values: [TaskContextState.ContextFact],
        limit: Int
    ) -> [TaskContextState.ContextFact] {
        var seen = Set<String>()
        var output: [TaskContextState.ContextFact] = []
        for value in values {
            let trimmed = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            output.append(value)
            if output.count >= limit { break }
        }
        return output
    }

    private static func dedupeSourcePointers(
        _ values: [TaskContextState.SourcePointer]
    ) -> [TaskContextState.SourcePointer] {
        var seen = Set<String>()
        var output: [TaskContextState.SourcePointer] = []
        for value in values {
            let key = [
                value.kind,
                value.id ?? "",
                value.path ?? "",
                value.summary
            ].joined(separator: "\u{1F}")
            guard seen.insert(key).inserted else { continue }
            output.append(value)
        }
        return output
    }

    private static func sourceSummary(_ source: TaskContextState.SourcePointer) -> String {
        var parts = [source.kind]
        if let id = source.id, !id.isEmpty {
            parts.append(String(id.prefix(8)))
        }
        if let path = source.path, !path.isEmpty {
            parts.append((path as NSString).lastPathComponent)
        }
        if !source.summary.isEmpty {
            parts.append(source.summary)
        }
        return parts.joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension Array {
    func prefixArray(_ maxLength: Int) -> [Element] {
        Array(prefix(maxLength))
    }
}
