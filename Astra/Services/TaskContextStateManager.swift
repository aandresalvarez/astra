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
    var turns: [Turn]
    var updatedAt: String
}

enum TaskContextStateManager {
    static let jsonFileName = "current_state.json"
    static let markdownFileName = "current_state.md"

    private static let schemaVersion = 1
    private static let maxTurns = 12
    private static let maxListItems = 20
    private static let maxPromptTurns = 4
    private static let promptBlockCharacterLimit = 6_000

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

    static func load(taskFolder: String) -> TaskContextState? {
        let url = URL(fileURLWithPath: taskFolder).appendingPathComponent(jsonFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TaskContextState.self, from: data),
              decoded.schemaVersion == schemaVersion else {
            return nil
        }
        return decoded
    }

    static func promptContext(for task: AgentTask) -> String? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty, let state = load(taskFolder: folder) else { return nil }

        var lines: [String] = []
        lines.append("Thread Intent:")
        lines.append("- Mode: \(state.mode.rawValue)")
        if !state.startingRequest.isEmpty {
            lines.append("- Starting request: \(boundedInline(state.startingRequest, maxCharacters: 240))")
        }
        if !state.currentObjective.isEmpty {
            lines.append("- Current objective: \(boundedInline(state.currentObjective, maxCharacters: 320))")
        }
        if let approvedGoal = state.approvedGoal, !approvedGoal.isEmpty {
            lines.append("- Approved goal: \(boundedInline(approvedGoal, maxCharacters: 320))")
        }
        appendList("Decisions", state.decisions, to: &lines, limit: 6)
        appendList("Open questions", state.openQuestions, to: &lines, limit: 5)
        appendList("Blockers", state.blockers, to: &lines, limit: 5)
        appendList("Files changed", state.filesChanged, to: &lines, limit: 8)
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
        let outputChars = outputFiles.reduce(0) { total, path in
            total + fileSize(path)
        }

        return [
            "phase": phase,
            "prompt_chars": String(prompt.count),
            "estimated_prompt_tokens": String(max(1, prompt.count / 4)),
            "has_thread_intent": String(prompt.contains("Thread Intent:")),
            "task_folder_present": String(!folder.isEmpty),
            "state_json_chars": String(fileSize(stateJSONPath)),
            "state_md_chars": String(fileSize(stateMDPath)),
            "session_history_chars": String(fileSize(historyPath)),
            "output_file_count": String(outputFiles.count),
            "output_chars_total": String(outputChars)
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
        appendMarkdownSection("Decisions", state.decisions, to: &parts)
        appendMarkdownSection("Rejected options", state.rejectedOptions, to: &parts)
        appendMarkdownSection("Open questions", state.openQuestions, to: &parts)
        appendMarkdownSection("Candidate goals", state.candidateGoals, to: &parts)
        appendMarkdownSection("Blockers", state.blockers, to: &parts)
        appendMarkdownSection("Files changed", state.filesChanged, to: &parts)
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

    private static func initialState(for task: AgentTask) -> TaskContextState {
        TaskContextState(
            schemaVersion: schemaVersion,
            mode: .exploration,
            startingRequest: task.goal,
            currentObjective: task.goal,
            decisions: [],
            rejectedOptions: [],
            openQuestions: [],
            candidateGoals: [],
            approvedGoal: nil,
            blockers: [],
            filesChanged: [],
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
            state.startingRequest,
            firstConversationRequest(for: task),
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
            outputFile: latestOutputFile(in: taskFolder) ?? formattedOutputFileName(turn: number),
            runStatus: run.status.rawValue,
            completedAt: run.completedAt.map(timestamp)
        )
    }

    @MainActor
    private static func latestRun(for task: AgentTask) -> TaskRun? {
        task.runs.max { $0.startedAt < $1.startedAt }
    }

    @MainActor
    private static func firstConversationRequest(for task: AgentTask) -> String? {
        task.events
            .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
            .sorted { $0.timestamp < $1.timestamp }
            .first?
            .payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let latest = latestOutputFile(in: taskFolder),
           let parsed = parseTurnNumber(fromOutputFile: latest) {
            return parsed
        }
        return (state.turns.map(\.turn).max() ?? 0) + 1
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

    private static func appendList(_ label: String, _ values: [String], to lines: inout [String], limit: Int) {
        let items = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(limit)
        guard !items.isEmpty else { return }
        lines.append("- \(label):")
        for value in items {
            lines.append("  - \(boundedInline(value, maxCharacters: 280))")
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
