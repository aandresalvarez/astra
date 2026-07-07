import Foundation
import ASTRACore
import ASTRAModels

public enum TaskThreadMode: String, Codable, Sendable, Equatable {
    case exploration
    case planning
    case execution
    case blocked
    case completed
}

public struct TaskContextState: Codable, Sendable, Equatable {
    public struct Turn: Codable, Sendable, Equatable {
        public init(turn: Int, ask: String, summary: String, filesChanged: [String], blockers: [String], outputFile: String? = nil, runStatus: String, completedAt: String? = nil) {
            self.turn = turn
            self.ask = ask
            self.summary = summary
            self.filesChanged = filesChanged
            self.blockers = blockers
            self.outputFile = outputFile
            self.runStatus = runStatus
            self.completedAt = completedAt
        }

        public var turn: Int
        public var ask: String
        public var summary: String
        public var filesChanged: [String]
        public var blockers: [String]
        public var outputFile: String?
        public var runStatus: String
        public var completedAt: String?
    }

    // Extracted to ASTRACore/TaskContextSourcePointer.swift as part of Track
    // A3 - Astra/Models/TaskMissionHardening.swift needs it. Every existing
    // `TaskContextState.SourcePointer`/bare `SourcePointer` reference in
    // this file keeps working unchanged via this alias.
    public typealias SourcePointer = TaskContextSourcePointer

    public struct ContextFact: Codable, Sendable, Equatable, Hashable {
        public init(text: String, sourcePointers: [SourcePointer], confidence: String) {
            self.text = text
            self.sourcePointers = sourcePointers
            self.confidence = confidence
        }

        public var text: String
        public var sourcePointers: [SourcePointer]
        public var confidence: String
    }

    public struct Objective: Codable, Sendable, Equatable {
        public init(startingRequest: String, currentObjective: String, approvedGoal: String? = nil, sourcePointers: [SourcePointer]) {
            self.startingRequest = startingRequest
            self.currentObjective = currentObjective
            self.approvedGoal = approvedGoal
            self.sourcePointers = sourcePointers
        }

        public var startingRequest: String
        public var currentObjective: String
        public var approvedGoal: String?
        public var sourcePointers: [SourcePointer]
    }

    public struct Verification: Codable, Sendable, Equatable {
        public struct DeliverableCheckSummary: Codable, Sendable, Equatable, Hashable {
            public init(id: String, title: String, status: String, summary: String, path: String? = nil) {
                self.id = id
                self.title = title
                self.status = status
                self.summary = summary
                self.path = path
            }

            public var id: String
            public var title: String
            public var status: String
            public var summary: String
            public var path: String?
        }

        public var status: String
        public var strategy: String
        public var command: String?
        public var summary: String
        public var evidence: [SourcePointer]
        public var updatedAt: String?
        public var completionVerified: Bool
        public var artifactStatus: String
        public var deliverableLevel: String?
        public var deliverableSummary: String?
        public var deliverableChecks: [DeliverableCheckSummary]

        public init(
            status: String,
            strategy: String,
            command: String? = nil,
            summary: String,
            evidence: [SourcePointer],
            updatedAt: String? = nil,
            completionVerified: Bool? = nil,
            artifactStatus: String = "unknown",
            deliverableLevel: String? = nil,
            deliverableSummary: String? = nil,
            deliverableChecks: [DeliverableCheckSummary] = []
        ) {
            self.status = status
            self.strategy = strategy
            self.command = command
            self.summary = summary
            self.evidence = evidence
            self.updatedAt = updatedAt
            self.completionVerified = completionVerified ?? (status == "passed")
            self.artifactStatus = artifactStatus
            self.deliverableLevel = deliverableLevel
            self.deliverableSummary = deliverableSummary
            self.deliverableChecks = deliverableChecks
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case strategy
            case command
            case summary
            case evidence
            case updatedAt
            case completionVerified
            case artifactStatus
            case deliverableLevel
            case deliverableSummary
            case deliverableChecks
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            strategy = try container.decode(String.self, forKey: .strategy)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            summary = try container.decode(String.self, forKey: .summary)
            evidence = try container.decode([SourcePointer].self, forKey: .evidence)
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            let decodedCompletionVerified = try container.decodeIfPresent(Bool.self, forKey: .completionVerified)
            completionVerified = decodedCompletionVerified ?? (status == "passed")
            artifactStatus = try container.decodeIfPresent(String.self, forKey: .artifactStatus) ?? "unknown"
            deliverableLevel = try container.decodeIfPresent(String.self, forKey: .deliverableLevel)
            deliverableSummary = try container.decodeIfPresent(String.self, forKey: .deliverableSummary)
            deliverableChecks = try container.decodeIfPresent(
                [DeliverableCheckSummary].self,
                forKey: .deliverableChecks
            ) ?? []
        }
    }

    public struct ChangedFile: Codable, Sendable, Equatable, Hashable {
        public init(path: String, changeType: String, sourcePointers: [SourcePointer]) {
            self.path = path
            self.changeType = changeType
            self.sourcePointers = sourcePointers
        }

        public var path: String
        public var changeType: String
        public var sourcePointers: [SourcePointer]
    }

    public struct ArtifactReference: Codable, Sendable, Equatable, Hashable {
        public init(type: String, path: String, version: Int, isStale: Bool, sourcePointers: [SourcePointer]) {
            self.type = type
            self.path = path
            self.version = version
            self.isStale = isStale
            self.sourcePointers = sourcePointers
        }

        public var type: String
        public var path: String
        public var version: Int
        public var isStale: Bool
        public var sourcePointers: [SourcePointer]
    }

    public struct ValidationAssertionSummary: Codable, Sendable, Equatable, Hashable {
        public init(id: String, scope: String, stepID: String? = nil, method: String, required: Bool, description: String, status: String, summary: String? = nil, sourcePointers: [SourcePointer]) {
            self.id = id
            self.scope = scope
            self.stepID = stepID
            self.method = method
            self.required = required
            self.description = description
            self.status = status
            self.summary = summary
            self.sourcePointers = sourcePointers
        }

        public var id: String
        public var scope: String
        public var stepID: String?
        public var method: String
        public var required: Bool
        public var description: String
        public var status: String
        public var summary: String?
        public var sourcePointers: [SourcePointer]
    }

    public struct ValidationContractSummary: Codable, Sendable, Equatable, Hashable {
        public init(status: String, assertionCount: Int, requiredPassed: Int, requiredTotal: Int, assertions: [ValidationAssertionSummary], sourcePointers: [SourcePointer]) {
            self.status = status
            self.assertionCount = assertionCount
            self.requiredPassed = requiredPassed
            self.requiredTotal = requiredTotal
            self.assertions = assertions
            self.sourcePointers = sourcePointers
        }

        public var status: String
        public var assertionCount: Int
        public var requiredPassed: Int
        public var requiredTotal: Int
        public var assertions: [ValidationAssertionSummary]
        public var sourcePointers: [SourcePointer]
    }

    public struct HandoffSummary: Codable, Sendable, Equatable, Hashable {
        public init(runID: String, taskStatus: String, runStatus: String, completedWork: [String], unfinishedWork: [String], blockers: [String], suggestedNextAction: String? = nil, sourcePointers: [SourcePointer]) {
            self.runID = runID
            self.taskStatus = taskStatus
            self.runStatus = runStatus
            self.completedWork = completedWork
            self.unfinishedWork = unfinishedWork
            self.blockers = blockers
            self.suggestedNextAction = suggestedNextAction
            self.sourcePointers = sourcePointers
        }

        public var runID: String
        public var taskStatus: String
        public var runStatus: String
        public var completedWork: [String]
        public var unfinishedWork: [String]
        public var blockers: [String]
        public var suggestedNextAction: String?
        public var sourcePointers: [SourcePointer]
    }

    public struct CorrectiveWorkSummary: Codable, Sendable, Equatable, Hashable {
        public init(correctiveStepID: String, failedAssertionID: String, status: String, failureSummary: String, suggestedRepair: String, correctiveTaskID: String? = nil, dismissedReason: String? = nil, sourcePointers: [SourcePointer]) {
            self.correctiveStepID = correctiveStepID
            self.failedAssertionID = failedAssertionID
            self.status = status
            self.failureSummary = failureSummary
            self.suggestedRepair = suggestedRepair
            self.correctiveTaskID = correctiveTaskID
            self.dismissedReason = dismissedReason
            self.sourcePointers = sourcePointers
        }

        public var correctiveStepID: String
        public var failedAssertionID: String
        public var status: String
        public var failureSummary: String
        public var suggestedRepair: String
        public var correctiveTaskID: String?
        public var dismissedReason: String?
        public var sourcePointers: [SourcePointer]
    }

    public init(
        schemaVersion: Int,
        mode: TaskThreadMode,
        startingRequest: String,
        currentObjective: String,
        objective: Objective,
        constraints: [ContextFact],
        acceptanceCriteria: [ContextFact],
        testCommand: String? = nil,
        decisions: [String],
        decisionFacts: [ContextFact],
        rejectedOptions: [String],
        openQuestions: [String],
        candidateGoals: [String],
        approvedGoal: String? = nil,
        blockers: [String],
        blockerFacts: [ContextFact],
        filesChanged: [String],
        changedFiles: [ChangedFile],
        artifacts: [ArtifactReference],
        verification: Verification,
        validationContract: ValidationContractSummary? = nil,
        latestHandoff: HandoffSummary? = nil,
        correctiveWork: [CorrectiveWorkSummary]? = nil,
        sourcePointers: [SourcePointer],
        nextLikelyAction: String? = nil,
        objectiveDivergenceNote: String? = nil,
        standingInstructions: [ContextFact]? = nil,
        objectiveAssessment: ObjectiveAssessment? = nil,
        turns: [Turn],
        updatedAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.startingRequest = startingRequest
        self.currentObjective = currentObjective
        self.objective = objective
        self.constraints = constraints
        self.acceptanceCriteria = acceptanceCriteria
        self.testCommand = testCommand
        self.decisions = decisions
        self.decisionFacts = decisionFacts
        self.rejectedOptions = rejectedOptions
        self.openQuestions = openQuestions
        self.candidateGoals = candidateGoals
        self.approvedGoal = approvedGoal
        self.blockers = blockers
        self.blockerFacts = blockerFacts
        self.filesChanged = filesChanged
        self.changedFiles = changedFiles
        self.artifacts = artifacts
        self.verification = verification
        self.validationContract = validationContract
        self.latestHandoff = latestHandoff
        self.correctiveWork = correctiveWork
        self.sourcePointers = sourcePointers
        self.nextLikelyAction = nextLikelyAction
        self.objectiveDivergenceNote = objectiveDivergenceNote
        self.standingInstructions = standingInstructions
        self.objectiveAssessment = objectiveAssessment
        self.turns = turns
        self.updatedAt = updatedAt
    }

    public var schemaVersion: Int
    public var mode: TaskThreadMode
    public var startingRequest: String
    public var currentObjective: String
    public var objective: Objective
    public var constraints: [ContextFact]
    public var acceptanceCriteria: [ContextFact]
    public var testCommand: String?
    public var decisions: [String]
    public var decisionFacts: [ContextFact]
    public var rejectedOptions: [String]
    public var openQuestions: [String]
    public var candidateGoals: [String]
    public var approvedGoal: String?
    public var blockers: [String]
    public var blockerFacts: [ContextFact]
    public var filesChanged: [String]
    public var changedFiles: [ChangedFile]
    public var artifacts: [ArtifactReference]
    public var verification: Verification
    public var validationContract: ValidationContractSummary?
    public var latestHandoff: HandoffSummary?
    public var correctiveWork: [CorrectiveWorkSummary]?
    public var sourcePointers: [SourcePointer]
    public var nextLikelyAction: String?
    /// Set when an unreconciled plan goal diverges from the task goal; surfaced in
    /// the capsule so the drift cannot silently re-anchor the objective.
    public var objectiveDivergenceNote: String?
    /// Recent follow-up user messages, kept close to as-typed, so mid-conversation
    /// instructions survive past the transcript window (first message excluded).
    public var standingInstructions: [ContextFact]?
    public var objectiveAssessment: ObjectiveAssessment?
    public var turns: [Turn]
    public var updatedAt: String
}

public struct TaskContextStateLoadResult: Equatable, Sendable {
    public init(status: Status, path: String, state: TaskContextState? = nil, errorDescription: String? = nil, decodeDiagnostic: StructuredJSONDecodeDiagnostic? = nil) {
        self.status = status
        self.path = path
        self.state = state
        self.errorDescription = errorDescription
        self.decodeDiagnostic = decodeDiagnostic
    }

    public enum Status: String, Sendable {
        case loadedCurrent
        case migratedLegacy
        case missingFile
        case unreadableFile
        case decodeFailed
        case unsupportedSchema
    }

    public var status: Status
    public var path: String
    public var state: TaskContextState?
    public var errorDescription: String?
    public var decodeDiagnostic: StructuredJSONDecodeDiagnostic?

    public var didLoad: Bool {
        state != nil
    }
}

public struct TaskContextStateSaveResult: Equatable, Sendable {
    public init(status: Status, jsonPath: String, markdownPath: String, errorDescription: String? = nil) {
        self.status = status
        self.jsonPath = jsonPath
        self.markdownPath = markdownPath
        self.errorDescription = errorDescription
    }

    public enum Status: String, Sendable {
        case saved
        case createDirectoryFailed
        case encodeFailed
        case writeJSONFailed
        case writeMarkdownFailed
    }

    public var status: Status
    public var jsonPath: String
    public var markdownPath: String
    public var errorDescription: String?

    public var didSave: Bool {
        status == .saved
    }
}

public enum TaskContextStateManager {
    public static let jsonFileName = "current_state.json"
    public static let markdownFileName = "current_state.md"

    public static let schemaVersion = 2

    private static let maxTurns = 12
    private static let maxListItems = 20
    private static let maxPromptTurns = 4
    private static let maxStandingInstructions = 8
    private static let standingInstructionCharacterLimit = 280
    private static let promptBlockCharacterLimit = 6_000

    private struct LegacyTaskContextState: Decodable {
        public var schemaVersion: Int
        public var mode: TaskThreadMode
        public var startingRequest: String
        public var currentObjective: String
        public var decisions: [String]
        public var rejectedOptions: [String]
        public var openQuestions: [String]
        public var candidateGoals: [String]
        public var approvedGoal: String?
        public var blockers: [String]
        public var filesChanged: [String]
        public var nextLikelyAction: String?
        public var turns: [TaskContextState.Turn]
        public var updatedAt: String
    }

    @MainActor
    public static func recordTurn(task: AgentTask, run: TaskRun, message: String) {
        guard let folder = ensureTaskFolder(for: task) else { return }
        var state = TaskContextStateRecovery.recoverState(taskFolder: folder, taskID: task.id) ?? initialState(for: task)
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
    public static func refresh(task: AgentTask, followUpMessage: String = "") {
        guard let folder = ensureTaskFolder(for: task) else { return }
        let existing = TaskContextStateRecovery.recoverState(taskFolder: folder, taskID: task.id)
        var state = existing ?? initialState(for: task)
        updateDerivedFields(&state, task: task, latestRun: latestRun(for: task))
        reconcileActiveObjectiveWithAssessmentPivot(&state, task: task, followUpMessage: followUpMessage)
        // No-op refresh (common on task open) — skip the encode + two file writes. See perf audit.
        guard existing != state else { return }
        state.updatedAt = timestamp(Date())
        save(state, taskFolder: folder, taskID: task.id)
    }

    @MainActor
    public static func refreshedPromptContext(for task: AgentTask, followUpMessage: String = "") -> String? {
        refresh(task: task, followUpMessage: followUpMessage)
        return promptContext(for: task)
    }

    public static func loadResult(taskFolder: String) -> TaskContextStateLoadResult {
        let url = URL(fileURLWithPath: taskFolder).appendingPathComponent(jsonFileName)
        let accessRoot = URL(fileURLWithPath: taskFolder, isDirectory: true)
        let hostFileAccess = HostFileAccessBroker()
        let intent = HostFileAccessIntent.astraManagedStorage(root: accessRoot)
        guard hostFileAccess.fileExists(at: url, intent: intent) else {
            return TaskContextStateLoadResult(
                status: .missingFile,
                path: url.path,
                state: nil,
                errorDescription: nil,
                decodeDiagnostic: nil
            )
        }

        let data: Data
        do {
            data = try hostFileAccess.readData(at: url, intent: intent)
        } catch {
            return TaskContextStateLoadResult(
                status: .unreadableFile,
                path: url.path,
                state: nil,
                errorDescription: error.localizedDescription,
                decodeDiagnostic: nil
            )
        }

        let currentResult = StructuredJSONDecoder.decode(TaskContextState.self, from: data)
        if let decoded = currentResult.value {
            if decoded.schemaVersion == schemaVersion {
                return TaskContextStateLoadResult(
                    status: .loadedCurrent,
                    path: url.path,
                    state: decoded,
                    errorDescription: nil,
                    decodeDiagnostic: currentResult.diagnostic
                )
            }
            return TaskContextStateLoadResult(
                status: .unsupportedSchema,
                path: url.path,
                state: nil,
                errorDescription: "Unsupported Context Capsule schema version \(decoded.schemaVersion).",
                decodeDiagnostic: currentResult.diagnostic
            )
        }

        let legacyResult = StructuredJSONDecoder.decode(LegacyTaskContextState.self, from: data)
        if let legacy = legacyResult.value {
            guard legacy.schemaVersion == 1 else {
                return TaskContextStateLoadResult(
                    status: .unsupportedSchema,
                    path: url.path,
                    state: nil,
                    errorDescription: "Unsupported legacy Context Capsule schema version \(legacy.schemaVersion).",
                    decodeDiagnostic: legacyResult.diagnostic
                )
            }
            return TaskContextStateLoadResult(
                status: .migratedLegacy,
                path: url.path,
                state: migrateLegacyState(legacy, taskFolder: taskFolder),
                errorDescription: nil,
                decodeDiagnostic: legacyResult.diagnostic
            )
        }

        return TaskContextStateLoadResult(
            status: .decodeFailed,
            path: url.path,
            state: nil,
            errorDescription: [
                currentResult.diagnostic.errorDescription.map { "current: \($0)" },
                legacyResult.diagnostic.errorDescription.map { "legacy: \($0)" }
            ].compactMap { $0 }.joined(separator: "; "),
            decodeDiagnostic: currentResult.diagnostic
        )
    }

    public static func load(taskFolder: String) -> TaskContextState? {
        loadResult(taskFolder: taskFolder).state
    }

    public static func promptContext(for task: AgentTask) -> String? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty, let state = load(taskFolder: folder) else { return nil }

        var lines: [String] = []
        lines.append("Context Capsule v2:")
        if task.resolvedRuntimeID == .openCodeCLI {
            lines.append("- Treat this capsule as the authoritative compact task state. Use the inline transcript and summaries in this prompt as supporting evidence before requesting task-state file access.")
        } else {
            lines.append("- Treat this capsule as the authoritative compact task state. Use transcript, history, and output files as supporting evidence when exact prior wording or details are needed.")
        }
        lines.append("Thread Intent:")
        lines.append("- Mode: \(state.mode.rawValue)")
        if let checkpoint = checkpointSummary(for: task) {
            lines.append("Checkpoint:")
            lines.append("- \(boundedInline(checkpoint, maxCharacters: 420))")
            if let warning = TaskForkSourcePointerSeam.required.sourceAvailabilityWarning(for: task, fileManager: .default) {
                lines.append("- \(boundedInline(warning, maxCharacters: 240))")
            }
        }
        if !state.objective.startingRequest.isEmpty {
            lines.append("- Starting request: \(boundedInline(state.objective.startingRequest, maxCharacters: 240))")
        }
        if !state.objective.currentObjective.isEmpty, !MainActor.assumeIsolated({ shouldSuppressRedundantCurrentObjectiveLine(state: state, task: task) }) {
            lines.append("- Current objective: \(boundedInline(state.objective.currentObjective, maxCharacters: 320))")
        }
        if let approvedGoal = state.objective.approvedGoal, !approvedGoal.isEmpty, !MainActor.assumeIsolated({ shouldSuppressRedundantApprovedGoalLine(state: state, task: task) }) {
            lines.append("- Approved goal: \(boundedInline(approvedGoal, maxCharacters: 320))")
        }
        if let divergence = state.objectiveDivergenceNote, !divergence.isEmpty {
            lines.append("- Objective reconciliation: \(boundedInline(divergence, maxCharacters: 320))")
        }
        appendFactList("Constraints", state.constraints, to: &lines, limit: 6)
        appendFactList("Acceptance criteria", state.acceptanceCriteria, to: &lines, limit: 6)
        appendFactList(
            "Standing user instructions (recent follow-up directives; treat as binding unless superseded)",
            state.standingInstructions ?? [],
            to: &lines,
            limit: maxStandingInstructions
        )
        appendValidationContract(state.validationContract, to: &lines, limit: 8)
        if let testCommand = state.testCommand, !testCommand.isEmpty {
            lines.append("- Test command: \(boundedInline(testCommand, maxCharacters: 320))")
        }
        appendFactList("Decisions", MainActor.assumeIsolated({ decisionFactsExcludingRedundantApprovedGoal(state.decisionFacts, state: state, task: task) }), to: &lines, limit: 6)
        appendList("Open questions", state.openQuestions, to: &lines, limit: 5)
        appendFactList("Blockers", state.blockerFacts, to: &lines, limit: 5)
        appendChangedFiles(state.changedFiles, to: &lines, limit: 8)
        lines.append("- Verification: \(state.verification.status) via \(state.verification.strategy) - \(boundedInline(state.verification.summary, maxCharacters: 320))")
        lines.append("  - Completion verified: \(state.verification.completionVerified ? "yes" : "no")")
        lines.append("  - Artifact status: \(boundedInline(state.verification.artifactStatus, maxCharacters: 240))")
        if let deliverableLevel = state.verification.deliverableLevel, !deliverableLevel.isEmpty {
            lines.append("  - Deliverable quality: \(boundedInline(deliverableLevel, maxCharacters: 120))")
        }
        if let deliverableSummary = state.verification.deliverableSummary, !deliverableSummary.isEmpty {
            lines.append("  - Deliverable summary: \(boundedInline(deliverableSummary, maxCharacters: 320))")
        }
        appendDeliverableChecks(state.verification.deliverableChecks, to: &lines, limit: 4)
        if let command = state.verification.command, !command.isEmpty {
            lines.append("  - Verification command: \(boundedInline(command, maxCharacters: 320))")
        }
        appendSourcePointerList("Verification evidence", state.verification.evidence, to: &lines, limit: 4)
        appendArtifactReferences(state.artifacts, to: &lines, limit: 6)
        appendLatestHandoff(state.latestHandoff, to: &lines)
        appendObjectiveAssessment(state.objectiveAssessment, to: &lines)
        appendCorrectiveWork(state.correctiveWork, to: &lines, limit: 5)
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

        // Recovery pointers must survive truncation (prompt-assembly invariant:
        // "truncation must preserve a pointer"); reserve the tail, truncate only body.
        var tail: [String] = []
        if task.resolvedRuntimeID == .openCodeCLI {
            tail.append("- Canonical ASTRA state is already inlined in this capsule for OpenCode.")
            tail.append("- Use this inline capsule and recent transcript unless the user explicitly asks for raw file contents.")
        } else {
            let boundedFolder = boundedInline(folder, maxCharacters: 1024) // keep the reserved tail within budget for pathologically long paths
            tail.append("- Canonical state file: \(boundedFolder)/\(jsonFileName)")
            tail.append("- Read \(boundedFolder)/\(markdownFileName) or referenced turn outputs if this follow-up depends on older decisions, failures, changed files, or exact prior wording.")
        }

        let body = lines.joined(separator: "\n")
        let tailBlock = tail.joined(separator: "\n")
        let bodyLimit = promptBlockCharacterLimit - tailBlock.count - 1
        guard body.count > bodyLimit else { return body + "\n" + tailBlock }
        let notice = "\n... (thread intent truncated)"
        return String(body.prefix(max(0, bodyLimit - notice.count))) + notice + "\n" + tailBlock
    }

    public static func promptDiagnosticsFields(task: AgentTask, prompt: String, phase: String) -> [String: String] {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let historyPath = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent("session_history.md")
        let outputDirectory = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent("outputs")
        let stateJSONPath = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent(jsonFileName)
        let stateMDPath = folder.isEmpty ? "" : (folder as NSString).appendingPathComponent(markdownFileName)
        let outputFiles = outputTurnFiles(in: outputDirectory)
        let latestOutputBytes = outputFiles.last.map(fileSize) ?? 0

        return [
            "phase": phase,
            "prompt_chars": String(prompt.count),
            "estimated_prompt_tokens": String(max(1, prompt.count / 4)),
            "has_context_capsule": String(prompt.contains("Context Capsule v2:")),
            "has_thread_intent": String(prompt.contains("Thread Intent:")),
            "task_folder_present": String(!folder.isEmpty),
            "state_json_bytes": String(fileSize(stateJSONPath)),
            "state_md_bytes": String(fileSize(stateMDPath)),
            "session_history_bytes": String(fileSize(historyPath)),
            "output_file_count": String(outputFiles.count),
            "output_latest_bytes": String(latestOutputBytes)
        ].merging(CapsuleSelectionPressure.fields(forTaskFolder: folder, prompt: prompt)) { _, new in new }
    }

    public static func renderMarkdown(_ state: TaskContextState) -> String {
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
        if let divergence = state.objectiveDivergenceNote, !divergence.isEmpty {
            parts.append("- Objective reconciliation: \(divergence)")
        }
        appendMarkdownFacts("Constraints", state.constraints, to: &parts)
        appendMarkdownFacts("Acceptance Criteria", state.acceptanceCriteria, to: &parts)
        appendMarkdownFacts("Standing User Instructions", state.standingInstructions ?? [], to: &parts)
        appendMarkdownValidationContract(state.validationContract, to: &parts)
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
        appendMarkdownHandoff(state.latestHandoff, to: &parts)
        appendMarkdownObjectiveAssessment(state.objectiveAssessment, to: &parts)
        appendMarkdownCorrectiveWork(state.correctiveWork, to: &parts)
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
            verification: verificationState(task: task, latestRun: nil, artifacts: []),
            validationContract: nil,
            latestHandoff: nil,
            correctiveWork: nil,
            sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task context")],
            nextLikelyAction: nil,
            objectiveDivergenceNote: nil,
            standingInstructions: nil,
            turns: [],
            updatedAt: timestamp(Date())
        )
    }

    @MainActor
    private static func updateDerivedFields(_ state: inout TaskContextState, task: AgentTask, latestRun: TaskRun?) {
        let planState = TaskPlanReconstructionSeam.required.reconstruct(for: task)
        let discoveredTaskOutputFiles = TaskOutputDiscovery.files(for: task)
        state.mode = inferredMode(task: task, planState: planState, latestRun: latestRun)
        state.startingRequest = firstNonEmpty(
            firstConversationRequest(for: task),
            state.startingRequest,
            task.goal
        )
        let activeObjective = activeObjectiveResolution(
            for: task,
            planState: planState,
            startingRequest: state.startingRequest,
            approvedGoal: state.approvedGoal
        )
        state.currentObjective = activeObjective.objective
        state.objectiveDivergenceNote = objectiveDivergenceNote(
            task: task,
            planState: planState,
            activeObjective: activeObjective
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
        if let checkpoint = checkpointSummary(for: task) {
            state.decisions = dedupeKeepingOrder([checkpoint] + state.decisions, limit: maxListItems)
        }

        let planBlockers = planState.plan?.steps.compactMap { step -> String? in
            guard step.status == .blocked else { return nil }
            let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Blocked step: \(step.title)" : "Blocked step: \(step.title) - \(detail)"
        } ?? []
        let eventBlockers = activeEventBlockers(task: task, latestRun: latestRun, mode: state.mode)
        let eventBlockerMessages = eventBlockers.map { boundedInline($0.payload, maxCharacters: 220) }
        state.blockers = dedupeKeepingOrder(planBlockers + eventBlockerMessages, limit: maxListItems)

        let access = TaskWorkspaceAccess(task: task)
        let changedFiles = task.runs
            .sorted { $0.startedAt < $1.startedAt }
            .flatMap(\.fileChanges)
            .map(\.path)
            .filter { isUserFacingOutputPath($0, task: task, access: access) }
        let discoveredChangedFiles = discoveredTaskOutputFiles.map(\.path)
        state.filesChanged = dedupeKeepingOrder(
            (state.filesChanged + changedFiles + discoveredChangedFiles)
                .filter { isUserFacingOutputPath($0, task: task, access: access) },
            limit: 50
        )
        state.openQuestions = dedupeKeepingOrder(state.openQuestions + recentQuestions(for: task), limit: 10)
        state.nextLikelyAction = nextLikelyAction(task: task, planState: planState)
        state.objective = objectiveState(task: task, planState: planState, state: state)
        state.constraints = task.constraints.map {
            contextFact($0, sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task constraint")])
        }
        state.acceptanceCriteria = task.acceptanceCriteria.map {
            contextFact($0, sourcePointers: [sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task acceptance criterion")])
        }
        let standing = standingUserInstructions(for: task)
        state.standingInstructions = standing.isEmpty ? nil : standing
        state.testCommand = normalizedTestCommand(task)
        state.decisionFacts = decisionFacts(for: state, task: task, planState: planState)
        state.blockerFacts = blockerFacts(for: task, planBlockers: planBlockers, eventBlockers: eventBlockers)
        state.changedFiles = changedFileReferences(for: task, discoveredFiles: discoveredTaskOutputFiles, access: access)
        state.artifacts = artifactReferences(for: task, discoveredFiles: discoveredTaskOutputFiles, access: access)
        state.verification = verificationState(task: task, latestRun: latestRun, artifacts: state.artifacts)
        state.validationContract = validationContractState(task: task, planState: planState)
        state.latestHandoff = latestHandoffState(task: task)
        state.correctiveWork = correctiveWorkState(task: task)
        state.sourcePointers = sourcePointers(for: task, state: state)
    }

    @discardableResult
    public static func saveState(_ state: TaskContextState, taskFolder: String, taskID: UUID? = nil) -> TaskContextStateSaveResult {
        let result = saveStateWithoutAudit(state, taskFolder: taskFolder)
        auditSaveResult(result, state: state, taskID: taskID)
        return result
    }

    private static func save(_ state: TaskContextState, taskFolder: String, taskID: UUID?) {
        _ = saveState(state, taskFolder: taskFolder, taskID: taskID)
    }

    private static func saveStateWithoutAudit(_ state: TaskContextState, taskFolder: String) -> TaskContextStateSaveResult {
        let folderURL = URL(fileURLWithPath: taskFolder)
        let jsonURL = folderURL.appendingPathComponent(jsonFileName)
        let markdownURL = folderURL.appendingPathComponent(markdownFileName)
        do {
            try FileManager.default.createDirectory(atPath: taskFolder, withIntermediateDirectories: true)
        } catch {
            return TaskContextStateSaveResult(
                status: .createDirectoryFailed,
                jsonPath: jsonURL.path,
                markdownPath: markdownURL.path,
                errorDescription: error.localizedDescription
            )
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(state)
        } catch {
            return TaskContextStateSaveResult(
                status: .encodeFailed,
                jsonPath: jsonURL.path,
                markdownPath: markdownURL.path,
                errorDescription: error.localizedDescription
            )
        }

        do {
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            return TaskContextStateSaveResult(
                status: .writeJSONFailed,
                jsonPath: jsonURL.path,
                markdownPath: markdownURL.path,
                errorDescription: error.localizedDescription
            )
        }

        do {
            try renderMarkdown(state).write(
                to: markdownURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            return TaskContextStateSaveResult(
                status: .writeMarkdownFailed,
                jsonPath: jsonURL.path,
                markdownPath: markdownURL.path,
                errorDescription: error.localizedDescription
            )
        }

        return TaskContextStateSaveResult(
            status: .saved,
            jsonPath: jsonURL.path,
            markdownPath: markdownURL.path,
            errorDescription: nil
        )
    }

    private static func auditSaveResult(_ result: TaskContextStateSaveResult, state: TaskContextState, taskID: UUID?) {
        guard let taskID else { return }
        if result.didSave {
            AuditLoggingSeam.required.audit(.contextStateUpdated, category: "Worker", taskID: taskID, fields: [
                "mode": state.mode.rawValue,
                "turn_count": String(state.turns.count),
                "decision_count": String(state.decisions.count),
                "blocker_count": String(state.blockers.count),
                "file_count": String(state.filesChanged.count),
                "result": result.status.rawValue
            ], level: .debug)
        } else {
            AuditLoggingSeam.required.audit(.contextStateUpdated, category: "Worker", taskID: taskID, fields: [
                "result": result.status.rawValue,
                "json_path": result.jsonPath,
                "markdown_path": result.markdownPath,
                "error": result.errorDescription ?? "unknown"
            ], level: .warning)
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
            validationContract: nil,
            latestHandoff: nil,
            correctiveWork: nil,
            sourcePointers: sourcePointers,
            nextLikelyAction: legacy.nextLikelyAction,
            objectiveDivergenceNote: nil,
            standingInstructions: nil,
            turns: legacy.turns,
            updatedAt: legacy.updatedAt
        )
    }

    @MainActor
    private static func ensureTaskFolder(for task: AgentTask) -> String? {
        let folder = (try? TaskWorkspaceAccess(task: task).ensureTaskFolder()) ?? ""
        return folder.isEmpty ? nil : folder
    }

    @MainActor
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
        let discoveredRunFiles = TaskOutputDiscovery.filesChanged(
            during: run,
            from: TaskOutputDiscovery.files(in: taskFolder)
        ).map(\.path)
        let access = TaskWorkspaceAccess(task: task)
        return TaskContextState.Turn(
            turn: number,
            ask: boundedInline(message, maxCharacters: 400),
            summary: summarizeOutput(run.output, fallback: run.stopReason),
            filesChanged: dedupeKeepingOrder(
                (run.fileChanges.map(\.path) + discoveredRunFiles)
                    .filter { isUserFacingOutputPath($0, task: task, access: access) },
                limit: 20
            ),
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
        let activeObjective = activeObjectiveResolution(
            for: task,
            planState: planState,
            startingRequest: state.startingRequest,
            approvedGoal: state.approvedGoal
        )
        sources += activeObjective.sourcePointers
        return TaskContextState.Objective(
            startingRequest: state.startingRequest,
            currentObjective: state.currentObjective,
            approvedGoal: state.approvedGoal,
            sourcePointers: dedupeSourcePointers(sources)
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
            let checkpointSource = checkpointSummary(for: task) == decision
                ? checkpointSourcePointer(for: task)
                : nil
            return contextFact(
                decision,
                sourcePointers: [checkpointSource ?? planSource ?? sourcePointer(kind: "task", id: task.id.uuidString, summary: "Task decision")]
            )
        }
    }

    @MainActor
    private static func blockerFacts(
        for task: AgentTask,
        planBlockers: [String],
        eventBlockers: [TaskEvent]
    ) -> [TaskContextState.ContextFact] {
        var facts = planBlockers.map {
            contextFact($0, sourcePointers: [sourcePointer(kind: "plan", id: nil, summary: "Blocked plan step")])
        }
        let eventFacts = eventBlockers
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
    private static func activeEventBlockers(
        task: AgentTask,
        latestRun: TaskRun?,
        mode: TaskThreadMode
    ) -> [TaskEvent] {
        guard mode == .blocked else { return [] }
        let blockingTypes = ["error", "permission.denied", "permission.approval.requested", "budget.exceeded"]
        let events = task.events
            .filter { blockingTypes.contains($0.type) }
            .sorted { $0.timestamp > $1.timestamp }
        guard let latestRun else {
            return Array(events.prefix(6))
        }
        let latestRunEvents = events.filter { $0.run?.id == latestRun.id }
        return Array((latestRunEvents.isEmpty ? events : latestRunEvents).prefix(6))
    }

    @MainActor
    private static func changedFileReferences(
        for task: AgentTask,
        discoveredFiles: [TaskOutputDiscoveredFile],
        access: TaskWorkspaceAccess
    ) -> [TaskContextState.ChangedFile] {
        let sortedRuns = task.runs.sorted { $0.startedAt < $1.startedAt }
        var output: [TaskContextState.ChangedFile] = []
        var indexByPath: [String: Int] = [:]

        for run in sortedRuns {
            for change in run.fileChanges {
                guard isUserFacingOutputPath(change.path, task: task, access: access) else { continue }
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
        for file in discoveredFiles {
            let pointer = sourcePointer(
                kind: "task_output_file",
                path: file.path,
                summary: "Discovered task output file \(file.relativePath)"
            )
            if let index = indexByPath[file.path] {
                output[index].sourcePointers = dedupeSourcePointers(output[index].sourcePointers + [pointer])
            } else {
                indexByPath[file.path] = output.count
                output.append(TaskContextState.ChangedFile(
                    path: file.path,
                    changeType: "discovered",
                    sourcePointers: [pointer]
                ))
            }
        }
        return Array(output.suffix(50))
    }

    @MainActor
    private static func artifactReferences(
        for task: AgentTask,
        discoveredFiles: [TaskOutputDiscoveredFile],
        access: TaskWorkspaceAccess
    ) -> [TaskContextState.ArtifactReference] {
        var references: [TaskContextState.ArtifactReference] = []
        var indexByPath: [String: Int] = [:]

        for artifact in task.artifacts.sorted(by: { $0.createdAt < $1.createdAt }) {
            let path = TaskArtifactPathNormalizer.normalizedPath(artifact.path, task: task)
            guard isUserFacingOutputPath(path, task: task, access: access) else { continue }
            let key = artifactReferenceKey(path)
            guard !key.isEmpty else { continue }

            let pointer = sourcePointer(
                kind: "artifact",
                id: artifact.id.uuidString,
                path: path,
                summary: "Generated artifact"
            )
            let incoming = TaskContextState.ArtifactReference(
                type: ArtifactKind(rawValue: artifact.type).rawValue,
                path: path,
                version: artifact.version,
                isStale: !FileManager.default.fileExists(atPath: path),
                sourcePointers: [pointer]
            )

            if let index = indexByPath[key] {
                let mergedSources = dedupeSourcePointers(references[index].sourcePointers + incoming.sourcePointers)
                if incoming.version >= references[index].version {
                    references[index] = TaskContextState.ArtifactReference(
                        type: incoming.type,
                        path: incoming.path,
                        version: incoming.version,
                        isStale: incoming.isStale,
                        sourcePointers: mergedSources
                    )
                } else {
                    references[index].sourcePointers = mergedSources
                }
            } else {
                indexByPath[key] = references.count
                references.append(incoming)
            }
        }

        for file in discoveredFiles {
            let key = artifactReferenceKey(file.path)
            guard !key.isEmpty else { continue }

            let pointer = sourcePointer(
                kind: "task_output_file",
                path: file.path,
                summary: "Discovered task output artifact \(file.relativePath)"
            )
            if let index = indexByPath[key] {
                references[index].sourcePointers = dedupeSourcePointers(references[index].sourcePointers + [pointer])
            } else {
                indexByPath[key] = references.count
                references.append(TaskContextState.ArtifactReference(
                    type: file.type,
                    path: file.path,
                    version: 1,
                    isStale: false,
                    sourcePointers: [pointer]
                ))
            }
        }
        return Array(references.suffix(30))
    }

    @MainActor
    private static func validationContractState(
        task: AgentTask,
        planState: TaskPlanState
    ) -> TaskContextState.ValidationContractSummary? {
        if let plan = planState.plan,
           let contract = plan.validationContract,
           !contract.assertions.isEmpty {
            return validationContractState(task: task, plan: plan, contract: contract)
        }

        return validationContractStateFromEvents(task: task)
    }

    private static func validationContractState(
        task: AgentTask,
        plan: TaskPlanPayload,
        contract: TaskValidationContract
    ) -> TaskContextState.ValidationContractSummary? {
        guard !contract.assertions.isEmpty else { return nil }

        let assertionEvents = latestAssertionEventsByID(task: task, planID: plan.planID)
        var requiredPassed = 0
        let assertions = contract.assertions.map { assertion in
            let eventPair = assertionEvents[assertion.id]
            let status = eventPair?.payload.status ?? "not_run"
            if assertion.required && status == "passed" {
                requiredPassed += 1
            }
            var sources = [
                sourcePointer(kind: "plan", id: plan.planID.uuidString, summary: "Validation contract assertion")
            ]
            if let event = eventPair?.event {
                sources.append(eventSource(event, summary: "Validation assertion \(status)"))
            }
            if let evidencePath = eventPair?.payload.evidence,
               evidencePath.hasPrefix("/") {
                sources.append(sourcePointer(
                    kind: "validation_evidence",
                    id: assertion.id,
                    path: evidencePath,
                    summary: "Validation evidence artifact"
                ))
            }
            return TaskContextState.ValidationAssertionSummary(
                id: assertion.id,
                scope: assertion.scope.rawValue,
                stepID: assertion.stepID,
                method: assertion.method.rawValue,
                required: assertion.required,
                description: boundedInline(assertion.description, maxCharacters: 320),
                status: status,
                summary: eventPair?.payload.summary,
                sourcePointers: dedupeSourcePointers(sources)
            )
        }

        let contractEvents = task.events.filter { event in
            guard [TaskValidationEventTypes.contractCreated,
                   TaskValidationEventTypes.contractUpdated,
                   TaskValidationEventTypes.contractPassed,
                   TaskValidationEventTypes.contractFailed,
                   TaskValidationEventTypes.contractOverridden].contains(event.type),
                  let payload = decodeContractPayload(event.payload) else {
                return false
            }
            return payload.planID == plan.planID
        }
        let latestContractOutcome = contractEvents
            .filter {
                [TaskValidationEventTypes.contractPassed,
                 TaskValidationEventTypes.contractFailed,
                 TaskValidationEventTypes.contractOverridden].contains($0.type)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .first
        let requiredTotal = contract.assertions.filter(\.required).count
        let hasStartedAssertions = assertions.contains { $0.status == "started" }
        let hasRequiredFailure = assertions.contains { $0.required && $0.status == "failed" }
        let allAssertionsTerminal = assertions.allSatisfy { summary in
            ["passed", "failed", "skipped", "reviewed"].contains(summary.status)
        }
        let status: String
        if latestContractOutcome?.type == TaskValidationEventTypes.contractOverridden {
            status = "overridden"
        } else if latestContractOutcome?.type == TaskValidationEventTypes.contractFailed {
            status = "failed"
        } else if latestContractOutcome?.type == TaskValidationEventTypes.contractPassed {
            status = "passed"
        } else if requiredTotal > 0 && requiredPassed == requiredTotal {
            status = "passed"
        } else if requiredTotal == 0 && allAssertionsTerminal && !hasStartedAssertions {
            status = "passed"
        } else if hasRequiredFailure {
            status = "failed"
        } else if hasStartedAssertions {
            status = "running"
        } else {
            status = "not_verified"
        }
        let eventPointers = contractEvents
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(4)
            .map { eventSource($0, summary: "Validation contract event \($0.type)") }

        return TaskContextState.ValidationContractSummary(
            status: status,
            assertionCount: contract.assertions.count,
            requiredPassed: requiredPassed,
            requiredTotal: requiredTotal,
            assertions: assertions,
            sourcePointers: dedupeSourcePointers(
                [sourcePointer(kind: "plan", id: plan.planID.uuidString, summary: "Validation contract")]
                    + eventPointers
            )
        )
    }

    private static func validationContractStateFromEvents(
        task: AgentTask
    ) -> TaskContextState.ValidationContractSummary? {
        let contractEvents = task.events.compactMap { event -> (event: TaskEvent, payload: TaskValidationContractEventPayload)? in
            guard [TaskValidationEventTypes.contractCreated,
                   TaskValidationEventTypes.contractUpdated,
                   TaskValidationEventTypes.contractPassed,
                   TaskValidationEventTypes.contractFailed,
                   TaskValidationEventTypes.contractOverridden].contains(event.type),
                  let payload = decodeContractPayload(event.payload) else {
                return nil
            }
            return (event, payload)
        }
        guard let latest = contractEvents.sorted(by: { $0.event.timestamp > $1.event.timestamp }).first else {
            return nil
        }

        let planID = latest.payload.planID
        let assertionEvents = latestAssertionEventsByID(task: task, planID: planID)
        let assertions = assertionEvents.values
            .sorted { lhs, rhs in
                lhs.payload.assertionID.localizedStandardCompare(rhs.payload.assertionID) == .orderedAscending
            }
            .map { pair in
                let payload = pair.payload
                var sources = [eventSource(pair.event, summary: "Validation assertion \(payload.status)")]
                if let evidence = payload.evidence,
                   evidence.hasPrefix("/") {
                    sources.append(sourcePointer(
                        kind: "validation_evidence",
                        id: payload.assertionID,
                        path: evidence,
                        summary: "Validation evidence artifact"
                    ))
                }
                return TaskContextState.ValidationAssertionSummary(
                    id: payload.assertionID,
                    scope: payload.scope.rawValue,
                    stepID: payload.stepID,
                    method: payload.method.rawValue,
                    required: payload.required,
                    description: boundedInline(payload.summary, maxCharacters: 320),
                    status: payload.status,
                    summary: payload.summary,
                    sourcePointers: dedupeSourcePointers(sources)
                )
            }
        let status = switch latest.event.type {
        case TaskValidationEventTypes.contractPassed:
            "passed"
        case TaskValidationEventTypes.contractFailed:
            "failed"
        case TaskValidationEventTypes.contractOverridden:
            "overridden"
        default:
            latest.payload.status
        }

        return TaskContextState.ValidationContractSummary(
            status: status,
            assertionCount: max(assertions.count, latest.payload.requiredTotal),
            requiredPassed: latest.payload.requiredPassed,
            requiredTotal: latest.payload.requiredTotal,
            assertions: assertions,
            sourcePointers: [eventSource(latest.event, summary: "Validation contract event \(latest.event.type)")]
        )
    }

    private static func latestAssertionEventsByID(
        task: AgentTask,
        planID: UUID
    ) -> [String: (event: TaskEvent, payload: TaskValidationAssertionEventPayload)] {
        var results: [String: (event: TaskEvent, payload: TaskValidationAssertionEventPayload)] = [:]
        let validationEventTypes = [
            TaskValidationEventTypes.assertionDefined,
            TaskValidationEventTypes.assertionStarted,
            TaskValidationEventTypes.assertionPassed,
            TaskValidationEventTypes.assertionFailed,
            TaskValidationEventTypes.assertionSkipped,
            TaskValidationEventTypes.assertionReviewed
        ]
        for event in task.events
            .filter({ validationEventTypes.contains($0.type) })
            .sorted(by: { $0.timestamp > $1.timestamp }) {
            guard let payload = decodeAssertionPayload(event.payload),
                  payload.planID == planID,
                  results[payload.assertionID] == nil else {
                continue
            }
            results[payload.assertionID] = (event, payload)
        }
        return results
    }

    @MainActor
    private static func latestHandoffState(task: AgentTask) -> TaskContextState.HandoffSummary? {
        guard let event = task.events
            .filter({ $0.type == TaskHandoffEventTypes.created || $0.type == TaskHandoffEventTypes.updated })
            .sorted(by: { $0.timestamp > $1.timestamp })
            .first,
            let payload = TaskWorkerHandoffCodec.decode(event.payload) else {
            return nil
        }

        return TaskContextState.HandoffSummary(
            runID: payload.runID.uuidString,
            taskStatus: payload.taskStatus,
            runStatus: payload.runStatus,
            completedWork: Array(payload.completedWork.prefix(8)),
            unfinishedWork: Array(payload.unfinishedWork.prefix(8)),
            blockers: Array(payload.blockers.prefix(8)),
            suggestedNextAction: payload.suggestedNextAction,
            sourcePointers: [eventSource(event, summary: "Structured worker handoff")]
        )
    }

    @MainActor
    private static func correctiveWorkState(task: AgentTask) -> [TaskContextState.CorrectiveWorkSummary]? {
        let records = TaskCorrectiveWorkQueries.latestCorrectiveSteps(for: task)
        guard !records.isEmpty else { return nil }
        return records.prefix(10).map { record in
            let payload = record.payload
            return TaskContextState.CorrectiveWorkSummary(
                correctiveStepID: TaskCorrectiveWorkQueries.normalizedCorrectiveStepID(payload),
                failedAssertionID: payload.failedAssertionID,
                status: payload.status,
                failureSummary: boundedInline(payload.failureSummary, maxCharacters: 360),
                suggestedRepair: boundedInline(payload.suggestedRepair, maxCharacters: 360),
                correctiveTaskID: payload.correctiveTaskID?.uuidString,
                dismissedReason: payload.dismissedReason,
                sourcePointers: [eventSource(record.event, summary: "Corrective work \(payload.status)")]
            )
        }
    }

    @MainActor
    private static func verificationState(
        task: AgentTask,
        latestRun: TaskRun?,
        artifacts: [TaskContextState.ArtifactReference]
    ) -> TaskContextState.Verification {
        let command = normalizedTestCommand(task)
        let artifactStatus = artifactVerificationStatus(for: artifacts)
        let latestValidation = task.events
            .filter(isValidationEvent)
            .sorted { $0.timestamp > $1.timestamp }
            .first
        let latestDeliverableVerification = task.events
            .filter(isDeliverableVerificationEvent)
            .sorted { $0.timestamp > $1.timestamp }
            .first

        if let event = latestValidation,
           latestDeliverableVerification == nil || event.timestamp >= latestDeliverableVerification!.timestamp {
            let status = verificationStatus(for: event)
            return TaskContextState.Verification(
                status: status,
                strategy: validationStrategy(for: task, event: event),
                command: command,
                summary: boundedInline(event.payload, maxCharacters: 500),
                evidence: [eventSource(event, summary: "Validation event")],
                updatedAt: timestamp(event.timestamp),
                completionVerified: status == "passed",
                artifactStatus: artifactStatus
            )
        }

        if let event = latestDeliverableVerification,
           let payload = TaskDeliverableVerificationCodec.decode(event.payload) {
            let evidence = dedupeSourcePointers(
                [eventSource(event, summary: "Deliverable verification \(payload.status)")]
                    + payload.evidencePaths.prefix(6).map {
                        sourcePointer(kind: "task_output_file", path: $0, summary: "Deliverable verification evidence")
                    }
            )
            return TaskContextState.Verification(
                status: payload.status,
                strategy: "deliverable_verification",
                command: command,
                summary: boundedInline(payload.summary, maxCharacters: 500),
                evidence: evidence,
                updatedAt: timestamp(payload.verifiedAt),
                completionVerified: payload.status == "passed",
                artifactStatus: artifactStatus,
                deliverableLevel: payload.level.rawValue,
                deliverableSummary: boundedInline(payload.summary, maxCharacters: 500),
                deliverableChecks: payload.checks.map(deliverableCheckSummary)
            )
        }

        if task.validationStrategy == .manual, task.status == .completed {
            return TaskContextState.Verification(
                status: "manual_completion",
                strategy: task.validationStrategy.rawValue,
                command: command,
                summary: "No automated verification evidence recorded.",
                evidence: latestRun.map { [sourcePointer(kind: "run", id: $0.id.uuidString, summary: "Completed run")] } ?? [],
                updatedAt: latestRun?.completedAt.map(timestamp),
                completionVerified: false,
                artifactStatus: artifactStatus
            )
        }

        if let latestRun, latestRun.status == .failed || latestRun.status == .timeout || latestRun.status == .budgetExceeded {
            return TaskContextState.Verification(
                status: latestRun.status.rawValue,
                strategy: task.validationStrategy.rawValue,
                command: command,
                summary: firstNonEmpty(latestRun.stopReason, "Latest run did not complete successfully."),
                evidence: [sourcePointer(kind: "run", id: latestRun.id.uuidString, summary: "Latest unsuccessful run")],
                updatedAt: latestRun.completedAt.map(timestamp),
                completionVerified: false,
                artifactStatus: artifactStatus
            )
        }

        return TaskContextState.Verification(
            status: "not_verified",
            strategy: task.validationStrategy.rawValue,
            command: command,
            summary: "No structured verification result has been recorded yet.",
            evidence: [],
            updatedAt: nil,
            completionVerified: false,
            artifactStatus: artifactStatus
        )
    }

    private static func artifactVerificationStatus(for artifacts: [TaskContextState.ArtifactReference]) -> String {
        guard !artifacts.isEmpty else { return "none recorded" }
        let staleCount = artifacts.filter(\.isStale).count
        let currentCount = artifacts.count - staleCount
        switch (currentCount, staleCount) {
        case (let current, 0):
            return "\(current) current"
        case (0, let stale):
            return "\(stale) stale"
        case (let current, let stale):
            return "\(current) current, \(stale) stale"
        }
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
        if let checkpointPointer = checkpointSourcePointer(for: task) {
            pointers.append(checkpointPointer)
        }
        pointers += TaskForkSourcePointerSeam.required.sourcePointers(for: task)
        pointers += state.verification.evidence
        if let validationContract = state.validationContract {
            pointers += validationContract.sourcePointers
            pointers += validationContract.assertions.flatMap(\.sourcePointers)
        }
        if let latestHandoff = state.latestHandoff {
            pointers += latestHandoff.sourcePointers
        }
        if let correctiveWork = state.correctiveWork {
            pointers += correctiveWork.flatMap(\.sourcePointers)
        }
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

    private static func checkpointSummary(for task: AgentTask) -> String? {
        guard let sourceID = task.forkedFromID else { return nil }
        let sourceRunNumber = max(0, task.forkedAtRunIndex) + 1
        return "Forked checkpoint from task \(sourceID.uuidString) after source run \(sourceRunNumber). Treat copied runs and events up to this checkpoint as this branch history; source runs after the checkpoint are not authoritative for this task."
    }

    private static func checkpointSourcePointer(for task: AgentTask) -> TaskContextState.SourcePointer? {
        guard let sourceID = task.forkedFromID else { return nil }
        return sourcePointer(
            kind: "checkpoint",
            id: sourceID.uuidString,
            summary: "Fork checkpoint after source run \(max(0, task.forkedAtRunIndex) + 1)"
        )
    }

    @MainActor
    private static func firstConversationRequest(for task: AgentTask) -> String? {
        firstConversationRequestValue(for: task)
    }

    @MainActor
    private static func firstConversationEvent(for task: AgentTask) -> TaskEvent? {
        firstConversationEventValue(for: task)
    }

    @MainActor
    private static func recentQuestions(for task: AgentTask) -> [String] {
        task.events
            .filter { $0.type == TaskPlanConversationEventTypes.assistantMessage || $0.type == "agent.response" }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
            .flatMap { questionSentences(in: $0.payload) }
    }

    /// Recent follow-up user messages, kept close to as-typed (whitespace-collapsed,
    /// length-capped), so a mid-conversation constraint survives past the transcript
    /// window. Excludes the first message (pinned as startingRequest) and bare
    /// acknowledgements; everything else is retained for the model to weigh.
    @MainActor
    private static func standingUserInstructions(for task: AgentTask) -> [TaskContextState.ContextFact] {
        let userMessages = task.events
            .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
            .sorted { $0.timestamp < $1.timestamp }
        guard userMessages.count > 1 else { return [] }

        var facts: [TaskContextState.ContextFact] = []
        var seen = Set<String>()
        // Most recent first so the newest follow-ups win the bounded slots.
        for event in userMessages.dropFirst().reversed() {
            // Bound once (built directly, not via contextFact, to avoid double-bounding).
            let text = boundedInline(event.payload, maxCharacters: standingInstructionCharacterLimit)
            guard !text.isEmpty, !isLowSignalAcknowledgement(text), !isGeneratedResumeInstruction(text) else { continue }
            guard seen.insert(text.lowercased()).inserted else { continue }
            facts.append(TaskContextState.ContextFact(
                text: text,
                sourcePointers: [eventSource(event, summary: "User follow-up instruction")],
                confidence: "follow_up"
            ))
            if facts.count >= maxStandingInstructions { break }
        }
        return facts.reversed()
    }

    /// True only when *every* word is a filler/ack token (e.g. "ok", "ok proceed").
    /// Any non-filler word keeps the message. Bare yes/no are deliberately NOT filler
    /// — a lone "no" is often a real course-correction this feature must not drop.
    private static func isLowSignalAcknowledgement(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        let fillerWords: Set<String> = [
            "ok", "okay", "k", "kk", "thanks", "thank", "you", "ty",
            "proceed", "continue", "go", "ahead", "do", "it",
            "sure", "great", "perfect", "nice", "cool", "done", "lgtm", "please",
            "now", "then", "sounds", "good", "sg", "ack", "got", "fine"
        ]
        return tokens.allSatisfy { fillerWords.contains($0) }
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

    @MainActor
    private static func nextLikelyAction(task: AgentTask, planState: TaskPlanState) -> String? {
        if let correction = TaskCorrectiveWorkQueries.openCorrectiveSteps(for: task).first {
            let payload = correction.payload
            return "Review corrective work for failed assertion \(payload.failedAssertionID): \(boundedInline(payload.suggestedRepair, maxCharacters: 220))"
        }
        if let plan = planState.plan,
           let nextStep = TaskPlanReconstructionSeam.required.nextExecutableStep(in: plan) {
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
        let summary = TaskRunAnswerPresentationPolicy.summaryText(
            rawText: output,
            fallback: fallback,
            maxLength: 700
        )
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No assistant output captured."
        }
        return boundedInline(summary, maxCharacters: 700)
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
        if event.type == TaskValidationEventTypes.contractPassed ||
            event.type == TaskValidationEventTypes.contractFailed ||
            event.type == TaskValidationEventTypes.contractOverridden {
            return true
        }
        if event.type == "task.completed" {
            return ValidationOutcomeMarker.testsPassed.matches(event.payload)
                || ValidationOutcomeMarker.aiCheckPassed.matches(event.payload)
        }
        guard event.type == "error" else { return false }
        return ValidationOutcomeMarker.testsFailed.matches(event.payload)
            || ValidationOutcomeMarker.validationError.matches(event.payload)
            || ValidationOutcomeMarker.aiCheckFlagged.matches(event.payload)
            || ValidationOutcomeMarker.aiCheckError.matches(event.payload)
    }

    private static func isDeliverableVerificationEvent(_ event: TaskEvent) -> Bool {
        event.type == TaskDeliverableVerificationEventTypes.passed ||
            event.type == TaskDeliverableVerificationEventTypes.reviewNeeded ||
            event.type == TaskDeliverableVerificationEventTypes.failed
    }

    private static func deliverableCheckSummary(
        _ check: TaskDeliverableCheck
    ) -> TaskContextState.Verification.DeliverableCheckSummary {
        TaskContextState.Verification.DeliverableCheckSummary(
            id: check.id,
            title: check.title,
            status: check.status.rawValue,
            summary: boundedInline(check.summary, maxCharacters: 500),
            path: check.path
        )
    }

    private static func verificationStatus(for event: TaskEvent) -> String {
        if event.type == TaskValidationEventTypes.contractPassed {
            return "passed"
        }
        if event.type == TaskValidationEventTypes.contractFailed {
            return "failed"
        }
        if event.type == TaskValidationEventTypes.contractOverridden {
            return "overridden"
        }
        if event.type == "task.completed" {
            return "passed"
        }
        if ValidationOutcomeMarker.validationError.matches(event.payload)
            || ValidationOutcomeMarker.aiCheckError.matches(event.payload) {
            return "error"
        }
        return "failed"
    }

    private static func decodeAssertionPayload(_ payload: String) -> TaskValidationAssertionEventPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskValidationAssertionEventPayload.self, from: data)
    }

    private static func decodeContractPayload(_ payload: String) -> TaskValidationContractEventPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskValidationContractEventPayload.self, from: data)
    }

    private static func validationStrategy(for task: AgentTask, event: TaskEvent) -> String {
        if event.type == TaskValidationEventTypes.contractPassed ||
            event.type == TaskValidationEventTypes.contractFailed ||
            event.type == TaskValidationEventTypes.contractOverridden {
            return "validation_contract"
        }
        return task.validationStrategy.rawValue
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

    private static func appendValidationContract(
        _ contract: TaskContextState.ValidationContractSummary?,
        to lines: inout [String],
        limit: Int
    ) {
        guard let contract else { return }
        lines.append("- Validation contract: \(contract.status) (\(contract.requiredPassed)/\(contract.requiredTotal) required assertions passed)")
        for assertion in contract.assertions.prefix(limit) {
            let required = assertion.required ? "required" : "optional"
            let step = assertion.stepID.map { " step:\($0)" } ?? ""
            lines.append("  - [\(assertion.status)] \(assertion.id) \(required) \(assertion.method)\(step): \(boundedInline(assertion.description, maxCharacters: 240))")
        }
    }

    private static func appendLatestHandoff(
        _ handoff: TaskContextState.HandoffSummary?,
        to lines: inout [String]
    ) {
        guard let handoff else { return }
        lines.append("- Latest handoff: run \(String(handoff.runID.prefix(8))) task \(handoff.taskStatus), run \(handoff.runStatus)")
        appendList("Handoff completed work", handoff.completedWork, to: &lines, limit: 4)
        appendList("Handoff unfinished work", handoff.unfinishedWork, to: &lines, limit: 4)
        appendList("Handoff blockers", handoff.blockers, to: &lines, limit: 4)
        if let next = handoff.suggestedNextAction, !next.isEmpty {
            lines.append("  - Handoff next action: \(boundedInline(next, maxCharacters: 260))")
        }
    }

    private static func appendCorrectiveWork(
        _ correctiveWork: [TaskContextState.CorrectiveWorkSummary]?,
        to lines: inout [String],
        limit: Int
    ) {
        let items = correctiveWork?.prefix(limit) ?? []
        guard !items.isEmpty else { return }
        lines.append("- Corrective work:")
        for item in items {
            let task = item.correctiveTaskID.map { " task:\(String($0.prefix(8)))" } ?? ""
            lines.append("  - [\(item.status)] \(item.correctiveStepID) assertion:\(item.failedAssertionID)\(task)")
            lines.append("    - Repair: \(boundedInline(item.suggestedRepair, maxCharacters: 260))")
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

    private static func appendDeliverableChecks(
        _ values: [TaskContextState.Verification.DeliverableCheckSummary],
        to lines: inout [String],
        limit: Int
    ) {
        let items = values.prefix(limit)
        guard !items.isEmpty else { return }
        lines.append("  - Deliverable checks:")
        for check in items {
            let path = check.path.map { " path: \(boundedInline($0, maxCharacters: 180))" } ?? ""
            lines.append("    - [\(check.status)] \(boundedInline(check.title, maxCharacters: 100))\(path): \(boundedInline(check.summary, maxCharacters: 220))")
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
        parts.append("- Completion verified: \(verification.completionVerified ? "yes" : "no")")
        parts.append("- Artifact status: \(verification.artifactStatus)")
        if let deliverableLevel = verification.deliverableLevel, !deliverableLevel.isEmpty {
            parts.append("- Deliverable quality: \(deliverableLevel)")
        }
        if let deliverableSummary = verification.deliverableSummary, !deliverableSummary.isEmpty {
            parts.append("- Deliverable summary: \(deliverableSummary)")
        }
        if !verification.deliverableChecks.isEmpty {
            parts.append("- Deliverable checks:")
            for check in verification.deliverableChecks.prefix(8) {
                let path = check.path.map { " `\($0)`" } ?? ""
                parts.append("  - [\(check.status)] \(check.title)\(path): \(check.summary)")
            }
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

    private static func appendMarkdownValidationContract(
        _ contract: TaskContextState.ValidationContractSummary?,
        to parts: inout [String]
    ) {
        guard let contract else { return }
        parts.append("")
        parts.append("## Validation Contract")
        parts.append("- Status: \(contract.status)")
        parts.append("- Required passed: \(contract.requiredPassed)/\(contract.requiredTotal)")
        parts.append("- Assertion count: \(contract.assertionCount)")
        for assertion in contract.assertions {
            let required = assertion.required ? "required" : "optional"
            let step = assertion.stepID.map { " step `\($0)`" } ?? ""
            parts.append("- [\(assertion.status)] `\(assertion.id)` \(required) \(assertion.method)\(step): \(assertion.description)")
            if let summary = assertion.summary, !summary.isEmpty {
                parts.append("  - Summary: \(summary)")
            }
            appendMarkdownSources(assertion.sourcePointers, to: &parts)
        }
    }

    private static func appendMarkdownHandoff(
        _ handoff: TaskContextState.HandoffSummary?,
        to parts: inout [String]
    ) {
        guard let handoff else { return }
        parts.append("")
        parts.append("## Latest Handoff")
        parts.append("- Run: \(handoff.runID)")
        parts.append("- Task status: \(handoff.taskStatus)")
        parts.append("- Run status: \(handoff.runStatus)")
        appendMarkdownList(label: "Completed work", handoff.completedWork, to: &parts)
        appendMarkdownList(label: "Unfinished work", handoff.unfinishedWork, to: &parts)
        appendMarkdownList(label: "Blockers", handoff.blockers, to: &parts)
        if let next = handoff.suggestedNextAction, !next.isEmpty {
            parts.append("- Next action: \(next)")
        }
        appendMarkdownSources(handoff.sourcePointers, to: &parts)
    }

    private static func appendMarkdownCorrectiveWork(
        _ correctiveWork: [TaskContextState.CorrectiveWorkSummary]?,
        to parts: inout [String]
    ) {
        guard let correctiveWork, !correctiveWork.isEmpty else { return }
        parts.append("")
        parts.append("## Corrective Work")
        for item in correctiveWork {
            parts.append("- [\(item.status)] `\(item.correctiveStepID)` for assertion `\(item.failedAssertionID)`")
            parts.append("  - Failure: \(item.failureSummary)")
            parts.append("  - Repair: \(item.suggestedRepair)")
            if let correctiveTaskID = item.correctiveTaskID {
                parts.append("  - Corrective task: \(correctiveTaskID)")
            }
            if let dismissedReason = item.dismissedReason, !dismissedReason.isEmpty {
                parts.append("  - Dismissed reason: \(dismissedReason)")
            }
            appendMarkdownSources(item.sourcePointers, to: &parts)
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

    private static func artifactReferenceKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.hasPrefix("/") else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
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
