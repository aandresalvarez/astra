import Darwin
import Foundation
import ASTRACore
import ASTRAPersistence
import ASTRAModels

// MARK: - Async Process Runner

/// Async-safe process runner using `terminationHandler` instead of blocking `waitUntilExit()`.
enum AsyncProcessRunner {

    struct Output {
        let exitCode: Int
        let stdout: String
        let stderr: String
    }

    final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var timedOut = false

        func markTimedOutIfRunning(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed, process.isRunning else { return false }
            timedOut = true
            return true
        }

        func markCompleted() -> (didComplete: Bool, didTimeOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return (false, timedOut) }
            completed = true
            return (true, timedOut)
        }
    }

    static func run(
        _ process: Process,
        stdout: Pipe?,
        stderr: Pipe?,
        timeoutSeconds: TimeInterval? = nil
    ) async -> Output {
        let state = RunState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    let completion = state.markCompleted()
                    guard completion.didComplete else { return }
                    let timedOut = completion.didTimeOut

                    let stdoutStr: String
                    if timedOut {
                        stdoutStr = ""
                    } else if let stdout {
                        stdoutStr = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    } else {
                        stdoutStr = ""
                    }

                    let stderrStr: String
                    if timedOut {
                        let timeoutText = timeoutSeconds.map {
                            "Process timed out after \(Int($0.rounded())) seconds."
                        } ?? "Process timed out."
                        stderrStr = timeoutText
                    } else if let stderr {
                        stderrStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    } else {
                        stderrStr = ""
                    }

                    continuation.resume(returning: Output(
                        exitCode: timedOut ? -1 : Int(proc.terminationStatus),
                        stdout: stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }

                do {
                    try process.run()
                    scheduleTimeoutIfNeeded(
                        timeoutSeconds: timeoutSeconds,
                        process: process,
                        state: state
                    )
                } catch {
                    guard state.markCompleted().didComplete else { return }
                    continuation.resume(returning: Output(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                }
            }
        } onCancel: {
            terminateProcessTree(process)
        }
    }

    private static func scheduleTimeoutIfNeeded(
        timeoutSeconds: TimeInterval?,
        process: Process,
        state: RunState
    ) {
        guard let timeoutSeconds, timeoutSeconds > 0 else { return }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
            guard state.markTimedOutIfRunning(process) else { return }
            terminateProcessTree(process)
        }
    }

    static func terminateProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        terminateDescendants(of: pid, signal: SIGTERM)
        process.terminate()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            terminateDescendants(of: pid, signal: SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private static func terminateDescendants(of pid: pid_t, signal: Int32) {
        for child in childPIDs(of: pid) {
            terminateDescendants(of: child, signal: signal)
            kill(child, signal)
        }
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } catch {
            return []
        }
    }
}

// MARK: - Task Spec

/// AI-assisted task spec extraction from natural language.
/// Uses the configured utility runtime to extract a structured task spec from user input.
struct TaskSpec: Codable {
    var title: String
    var goal: String
    var inputs: [String]
    var constraints: [String]
    var acceptanceCriteria: [String]
    var estimatedComplexity: String  // low, medium, high
    var clarifications: [String]?

    enum CodingKeys: String, CodingKey {
        case title
        case goal
        case inputs
        case constraints
        case acceptanceCriteria
        case estimatedComplexity
        case clarifications
    }

    static let empty = TaskSpec(
        title: "", goal: "", inputs: [], constraints: [],
        acceptanceCriteria: [], estimatedComplexity: "medium"
    )

    init(
        title: String,
        goal: String,
        inputs: [String],
        constraints: [String],
        acceptanceCriteria: [String],
        estimatedComplexity: String,
        clarifications: [String]? = nil
    ) {
        self.title = title
        self.goal = goal
        self.inputs = inputs
        self.constraints = constraints
        self.acceptanceCriteria = acceptanceCriteria
        self.estimatedComplexity = Self.normalizedComplexity(estimatedComplexity)
        self.clarifications = clarifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        goal = try container.decode(String.self, forKey: .goal)
        inputs = try Self.decodeStringList(forKey: .inputs, from: container)
        constraints = try Self.decodeStringList(forKey: .constraints, from: container)
        acceptanceCriteria = try Self.decodeStringList(forKey: .acceptanceCriteria, from: container)
        let rawComplexity = try container.decodeIfPresent(String.self, forKey: .estimatedComplexity) ?? "medium"
        estimatedComplexity = Self.normalizedComplexity(rawComplexity)
        clarifications = try container.decodeIfPresent([String].self, forKey: .clarifications)
    }

    private static func decodeStringList(
        forKey key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let value = try? container.decode(LooseJSONValue.self, forKey: key) {
            return value.stringList
        }
        return []
    }

    private static func normalizedComplexity(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "low" || normalized == "medium" || normalized == "high" {
            return normalized
        }
        if normalized.contains("high") {
            return "high"
        }
        if normalized.contains("medium") {
            return "medium"
        }
        if normalized.contains("low") {
            return "low"
        }
        return "medium"
    }
}

private enum LooseJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([LooseJSONValue])
    case object([String: LooseJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([LooseJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LooseJSONValue].self))
        }
    }

    var stringList: [String] {
        switch self {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .number(let value):
            return [String(value)]
        case .bool(let value):
            return [String(value)]
        case .array(let values):
            return values.flatMap(\.stringList)
        case .object(let values):
            return values.keys.sorted().compactMap { key in
                let nested = values[key]?.inlineDescription ?? ""
                return nested.isEmpty ? key : "\(key): \(nested)"
            }
        case .null:
            return []
        }
    }

    private var inlineDescription: String {
        switch self {
        case .string(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .array(let values):
            return values.flatMap(\.stringList).joined(separator: ", ")
        case .object(let values):
            return values.keys.sorted().compactMap { key in
                let nested = values[key]?.inlineDescription ?? ""
                return nested.isEmpty ? key : "\(key): \(nested)"
            }.joined(separator: ", ")
        case .null:
            return ""
        }
    }
}

enum SpecEngine {
    static let maxRetries = 2

    /// Auto-detect the default utility CLI path, checking common install locations.
    static var detectedClaudePath: String {
        RuntimePathResolver.detectClaudePath()
    }

    static let jsonSchema = """
    {
      "title": "string — short title under 60 chars",
      "goal": "string — clear description of what the agent should accomplish",
      "inputs": ["string — files or context the agent needs"],
      "constraints": ["string — things the agent must NOT do"],
      "acceptanceCriteria": ["string — how to verify the task is done"],
      "estimatedComplexity": "string — one of: low, medium, high",
      "clarifications": ["string — optional questions if the request is ambiguous"]
    }
    """

    static let extractionPrompt = """
    Given the following user request, extract a structured task specification for an AI agent. The task may involve code, data processing, document review, research, writing, or any other work.

    User request: "{USER_INPUT}"
    Working directory: "{WORKSPACE}"

    You must respond with a single JSON object matching this schema. No other text, no markdown fences, no explanation.

    Schema:
    \(jsonSchema)

    Required fields: title, goal, inputs, constraints, acceptanceCriteria, estimatedComplexity.
    Optional field: clarifications (include only if the request is ambiguous).
    Keep all fields concise. Return ONLY the JSON object.
    """

    /// Extract a task spec from natural language using the configured utility runtime.
    static func extract(
        userInput: String,
        workspacePath: String,
        claudePath: String = SpecEngine.detectedClaudePath,
        model: String = TaskExecutionDefaults.model,
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> Result<TaskSpec, SpecEngineError> {
        let utilityRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        let prompt = extractionPrompt
            .replacingOccurrences(of: "{USER_INPUT}", with: userInput)
            .replacingOccurrences(of: "{WORKSPACE}", with: workspacePath)

        AppLogger.audit(.specExtractionStarted, category: "Worker", fields: [
            "source": "single_input",
            "input_length": String(userInput.count)
        ])

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
                "exit_code": String(result.exitCode),
                "source": "single_input",
                "runtime": utilityRuntime.runtime.rawValue,
                "error": String(result.failureDetail.prefix(200))
            ], level: .error)
            return .failure(.providerError("Exit code \(result.exitCode): \(result.failureDetail)"))
        }

        return await parseSpecWithRetry(
            output: result.output,
            retryPromptBase: prompt,
            workspacePath: workspacePath,
            utilityRuntime: utilityRuntime
        )
    }

    /// Strip markdown code fences if present
    private static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove ```json ... ``` wrapping
        if cleaned.hasPrefix("```") {
            if let start = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: start)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// Multi-turn chat for task refinement. Takes conversation history and returns the utility runtime's response.
    static func chat(
        messages: [(role: String, content: String)],
        workspacePath: String,
        skillContext: String = "",
        claudePath: String = SpecEngine.detectedClaudePath,
        model: String = TaskExecutionDefaults.model,
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> Result<String, SpecEngineError> {
        let utilityRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        var systemContext = """
        You are helping the user define a task for an AI agent. The task could be anything — writing code, \
        analyzing data, reviewing documents, research, writing, or other work. \
        Ask clarifying questions if the request is vague. Help them think through constraints, \
        acceptance criteria, and edge cases. Be concise and conversational. \
        When the user seems ready, refer to ASTRA's visible primary action. In normal task-spec \
        conversations this is "Create Task"; in Goal/Plan Mode this is "Approve Plan". Do not invent \
        or rename the visible button label. \
        Working directory: \(workspacePath)
        """
        if !skillContext.isEmpty {
            systemContext += """


            IMPORTANT — Active Skills selected by the user:
            The following skills define what the agent knows and can do. When the user references concepts, \
            folders, services, or workflows mentioned in a skill's instructions, use the skill context to understand \
            their request — do NOT guess or ask for information already provided in the skill.

            \(skillContext)
            """
        }

        // Build a single prompt from conversation history
        var prompt = systemContext + "\n\nConversation so far:\n"
        for msg in messages {
            let label = msg.role == "user" ? "User" : "Assistant"
            prompt += "\(label): \(msg.content)\n"
        }
        prompt += "\nAssistant:"

        AppLogger.audit(.specExtractionStarted, category: "Worker", fields: [
            "source": "chat",
            "message_count": String(messages.count)
        ], level: .debug)

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
                "exit_code": String(result.exitCode),
                "source": "chat",
                "runtime": utilityRuntime.runtime.rawValue,
                "error": String(result.failureDetail.prefix(200))
            ], level: .error)
            return .failure(.providerError("Exit code \(result.exitCode): \(result.failureDetail)"))
        }

        return .success(result.output)
    }

    /// Generate a short, meaningful title (3-6 words) from a task goal.
    static func generateTitle(
        goal: String,
        workspacePath: String,
        claudePath: String = SpecEngine.detectedClaudePath,
        model: String = "claude-haiku-4-5-20251001",
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> String? {
        let baseRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        let prompt = """
        Generate a short title (3-6 words) for this task. Return ONLY the title, nothing else. \
        Use sentence case. Be specific about the action and subject. Examples:
        - "Review Jira ticket summary" not "Help with Jira"
        - "Fix login page CSS" not "Fix the bug"
        - "Analyze BRIE evaluation data" not "Data analysis task"

        Task: \(String(goal.prefix(500)))
        """

        let modelCandidates = [
            baseRuntime.model,
            AgentRuntimeAdapterRegistry.defaultModel(for: baseRuntime.runtime)
        ].reduce(into: [String]()) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }

        var lastFailureFields: [String: String] = [:]
        for candidate in modelCandidates {
            var candidateRuntime = baseRuntime
            candidateRuntime.model = candidate
            let result = await AgentUtilityRuntimeRunner.runPrompt(
                prompt,
                workspacePath: workspacePath,
                configuration: candidateRuntime
            )

            guard result.exitCode == 0 else {
                lastFailureFields = titleGenerationFailureFields(result: result, model: candidate)
                AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
                    "operation": "title_generation",
                    "model": candidate,
                    "runtime": candidateRuntime.runtime.rawValue,
                    "result": "candidate_failed",
                    "exit_code": String(result.exitCode),
                    "error_summary": lastFailureFields["error_summary"] ?? "none"
                ], level: .debug)
                continue
            }

            // Sanitise at the source: trim, strip quotes, and collapse the
            // occasional self-doubled output ("New greetingNew greeting") so the
            // stored title is clean and no view layer has to paper over it.
            let title = TaskTitleSanitizer.sanitizeGeneratedTitle(result.output)
            guard !title.isEmpty, title.count <= 80 else { continue }
            return title
        }

        var fields = lastFailureFields
        fields["operation"] = "title_generation"
        fields["result"] = "all_candidates_failed"
        fields["candidate_count"] = String(modelCandidates.count)
        AppLogger.audit(.specExtractionFailed, category: "Worker", fields: fields, level: .warning)
        return nil
    }

    private static func titleGenerationFailureFields(result: AgentUtilityRunResult, model: String) -> [String: String] {
        let rawSummary = !result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.error
            : result.output
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "model": model,
            "exit_code": String(result.exitCode),
            "stderr_chars": String(result.error.count),
            "stdout_chars": String(result.output.count),
            "error_summary": summary.isEmpty ? "empty_process_output" : String(summary.prefix(240))
        ]
    }

    /// Extract spec from a full conversation context instead of a single user input.
    static func extractFromConversation(
        messages: [(role: String, content: String)],
        workspacePath: String,
        claudePath: String = SpecEngine.detectedClaudePath,
        model: String = TaskExecutionDefaults.model,
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> Result<TaskSpec, SpecEngineError> {
        let utilityRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        var conversationText = ""
        for msg in messages {
            let label = msg.role == "user" ? "User" : "Assistant"
            conversationText += "\(label): \(msg.content)\n"
        }

        let prompt = """
        Given the following conversation, extract a structured task specification for an AI agent. The task may involve code, data processing, document review, research, writing, or any other work.

        Conversation:
        \(conversationText)
        Working directory: \(workspacePath)

        You must respond with a single JSON object matching this schema. No other text, no markdown fences, no explanation.

        Schema:
        \(jsonSchema)

        Required fields: title, goal, inputs, constraints, acceptanceCriteria, estimatedComplexity.
        Synthesize the full conversation into a complete spec. Return ONLY the JSON object.
        """

        AppLogger.audit(.specExtractionStarted, category: "Worker", fields: [
            "source": "conversation",
            "message_count": String(messages.count)
        ])

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            return .failure(.providerError("Exit code \(result.exitCode): \(result.failureDetail)"))
        }

        return await parseSpecWithRetry(
            output: result.output,
            retryPromptBase: prompt,
            workspacePath: workspacePath,
            utilityRuntime: utilityRuntime
        )
    }

    // MARK: - Retry Logic

    /// Parse JSON spec from utility runtime output, retrying up to `maxRetries` times on failure.
    private static func parseSpecWithRetry(
        output: String,
        retryPromptBase: String,
        workspacePath: String,
        utilityRuntime: AgentUtilityRuntimeConfiguration
    ) async -> Result<TaskSpec, SpecEngineError> {
        let jsonString = extractJSON(from: output)

        if let data = jsonString.data(using: .utf8),
           let spec = try? JSONDecoder().decode(TaskSpec.self, from: data) {
            AppLogger.audit(.specExtractionCompleted, category: "Worker", fields: [
                "attempt": "initial",
                "title_length": String(spec.title.count)
            ])
            return .success(spec)
        }

        // Retry with refined prompt
        for attempt in 1...maxRetries {
            AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
                "attempt": String(attempt),
                "max_retries": String(maxRetries),
                "reason": "json_parse_failed"
            ], level: .warning)

            let retryPrompt = """
            Your previous response was not valid JSON. Respond with ONLY a valid JSON object, no markdown fences, no explanation text.

            \(retryPromptBase)
            """

            let retryResult = await AgentUtilityRuntimeRunner.runPrompt(
                retryPrompt,
                workspacePath: workspacePath,
                configuration: utilityRuntime,
                toolMode: .readOnly
            )

            guard retryResult.exitCode == 0 else { continue }

            let retryJSON = extractJSON(from: retryResult.output)

            if let data = retryJSON.data(using: .utf8),
               let spec = try? JSONDecoder().decode(TaskSpec.self, from: data) {
                AppLogger.audit(.specExtractionCompleted, category: "Worker", fields: [
                    "attempt": String(attempt),
                    "title_length": String(spec.title.count)
                ])
                return .success(spec)
            }
        }

        AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
            "max_retries": String(maxRetries),
            "reason": "max_retries_exhausted"
        ], level: .error)
        return .failure(.parseError("Failed to parse JSON after \(maxRetries) retries"))
    }

    // MARK: - AI Skill Generation

    struct GeneratedSkill: Codable {
        var name: String
        var icon: String
        var description: String
        var allowedTools: [String]
        var disallowedTools: [String]?  // Ignored — kept for backwards compat with cached responses
        var behaviorInstructions: String
        var suggestedEnvVars: [SuggestedEnvVar]?
        var suggestedCustomTools: [String]?

        struct SuggestedEnvVar: Codable {
            var key: String
            var hint: String
        }
    }

    static func generateSkill(
        userIntent: String,
        claudePath: String = SpecEngine.detectedClaudePath,
        model: String = TaskExecutionDefaults.model,
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> Result<GeneratedSkill, SpecEngineError> {
        let utilityRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        let prompt = """
        The user wants to create a "skill" for an AI coding agent. A skill defines what tools the agent can use, behavioral constraints, and environment variables it needs.

        User's description: "\(userIntent)"

        Available tools (choose which to allow):
        - Read: Read file contents
        - Write: Create new files
        - Edit: Modify existing files
        - Bash: Run shell commands
        - Glob: Search for files by name
        - Grep: Search file contents
        - WebFetch: Fetch web page content
        - WebSearch: Search the web
        - Agent: Spawn sub-agents
        - NotebookEdit: Edit Jupyter notebooks

        Available SF Symbols for icons: eye, lock.shield, checkmark.seal, magnifyingglass, arrow.triangle.2.circlepath, doc.text, chart.bar, server.rack, shield, terminal, wrench, leaf, flask.fill, ticket, list.bullet.clipboard, network, cpu, bolt, puzzlepiece.extension

        Return ONLY valid JSON (no markdown, no explanation) with this structure:
        {
          "name": "short skill name (2-3 words)",
          "icon": "SF Symbol name from the list above",
          "description": "one-line description of what this skill does",
          "allowedTools": ["tools the agent CAN use"],
          "behaviorInstructions": "detailed instructions for the agent: what to do, how to authenticate, what APIs to use, formatting expectations, safety rules. Include any restrictions (e.g. 'do not modify files') as instructions, NOT as tool blocking. Be specific and actionable.",
          "suggestedEnvVars": [{"key": "ENV_VAR_NAME", "hint": "what value the user should provide"}],
          "suggestedCustomTools": ["any MCP or custom tool names needed, or empty array"]
        }

        Guidelines:
        - Be specific in behaviorInstructions — include API endpoints, auth methods, output formats
        - Only suggest env vars that are actually needed (API keys, tokens, URLs)
        - If the skill needs web access (APIs, fetching), include WebFetch in allowedTools
        - If the skill runs commands, include Bash
        - For safety constraints (e.g. read-only), put them in behaviorInstructions as clear rules — do NOT use disallowedTools
        - To call authenticated APIs, use Bash with curl/python and env var tokens — NOT WebFetch
        - Choose an icon that matches the skill's purpose
        """

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: NSHomeDirectory(),
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            return .failure(.providerError("Exit code \(result.exitCode): \(result.failureDetail)"))
        }

        let jsonString = extractJSON(from: result.output)

        guard let data = jsonString.data(using: .utf8) else {
            return .failure(.parseError("Could not encode response as data"))
        }

        do {
            let skill = try JSONDecoder().decode(GeneratedSkill.self, from: data)
            AppLogger.audit(.skillGenerated, category: "Worker", fields: [
                "name_length": String(skill.name.count),
                "allowed_tools_count": String(skill.allowedTools.count)
            ])
            return .success(skill)
        } catch {
            AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
                "reason": "skill_json_parse_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return .failure(.parseError("Failed to parse skill JSON: \(error.localizedDescription)"))
        }
    }
}

enum SpecEngineError: Error, LocalizedError {
    case processError(String)
    case providerError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .processError(let msg): return "Process error: \(msg)"
        case .providerError(let msg): return "Provider error: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
