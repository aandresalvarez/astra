import Foundation
import SwiftData
import ASTRACore

/// Thread-safe mutable string for use across readabilityHandler closures.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }; _value += s
    }
}

/// Thread-safe collector for fire-and-forget `Task` handles.
/// Allows callers to drain all pending tasks before proceeding.
final class PendingTaskCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return tasks.count
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }; tasks.append(task)
    }

    /// Take a snapshot of all collected tasks (synchronous, lock-safe).
    private func takeSnapshot() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }; return tasks
    }

    /// Await all collected tasks. Safe to call from any async context.
    func drainAll() async {
        for t in takeSnapshot() {
            await t.value
        }
    }
}

@Observable
final class ClaudeCodeWorker {
    private(set) var isRunning = false
    private var currentProcess: Process?
    private var cancellationRequested = false

    /// Path to the claude CLI. Auto-detected or set manually.
    var claudePath: String = "/usr/local/bin/claude"

    @MainActor
    init() {
        detectClaudePath()
        AppLogger.audit(.workerStarted, category: "Worker", fields: [
            "phase": "initialized",
            "claude_path_configured": String(!claudePath.isEmpty)
        ], level: .debug)
    }

    private func detectClaudePath() {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                claudePath = path
                return
            }
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            claudePath = path
        }
    }

    /// Execute a task by running Claude Code as a subprocess with stream-json output.
    @MainActor
    func execute(
        task: AgentTask,
        modelContext: ModelContext,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "status": task.status.rawValue,
            "model": task.model,
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])
        guard !isRunning else {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "reason": "worker_already_running"
            ], level: .warning)
            return
        }
        isRunning = true
        cancellationRequested = false

        task.status = .running
        task.updatedAt = Date()

        let run = TaskRun(task: task)
        modelContext.insert(run)

        let startEvent = TaskEvent(task: task, type: "task.started", payload: "Agent started working on: \(task.goal)", run: run)
        modelContext.insert(startEvent)

        // Verify CLI exists
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "claude_cli_not_found"
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            task.status = .failed
            task.updatedAt = Date()
            let event = TaskEvent(task: task, type: "error",
                payload: "Claude CLI not found at '\(claudePath)'. Check Settings.", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        // Use codeWorkingDirectory — prefers additional paths (actual code repo) over the Astra workspace folder
        let codeDir = task.codeWorkingDirectory
        // Verify workspace exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codeDir, isDirectory: &isDir), isDir.boolValue else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "workspace_not_found"
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            task.status = .failed
            task.updatedAt = Date()
            let event = TaskEvent(task: task, type: "error",
                payload: "Workspace directory not found: \(codeDir)", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        // Prepare workspace isolation
        let executionPath: String
        do {
            executionPath = try await IsolationService.prepare(task: task)
            if executionPath != task.effectiveWorkspacePath {
                let isoEvent = TaskEvent(task: task, type: "tool.use",
                    payload: "Isolation: \(task.isolationStrategy.rawValue) → \(executionPath)", run: run)
                modelContext.insert(isoEvent)
            }
        } catch {
            AppLogger.audit(.isolationFailed, category: "Isolation", taskID: task.id, fields: [
                "error_type": String(describing: type(of: error))
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            task.status = .failed
            task.updatedAt = Date()
            let event = TaskEvent(task: task, type: "error",
                payload: "Workspace isolation failed: \(error.localizedDescription)", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        let prompt = buildPrompt(for: task)
        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
            "model": task.model,
            "token_budget": String(task.tokenBudget),
            "isolation": task.isolationStrategy.rawValue,
            "workspace_changed": String(executionPath != task.effectiveWorkspacePath)
        ])

        // Log active skills
        if !task.skills.isEmpty {
            let skillNames = task.skills.map(\.name).joined(separator: ", ")
            let skillEvent = TaskEvent(task: task, type: "skill.active",
                payload: "Active skills: \(skillNames)", run: run)
            modelContext.insert(skillEvent)
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "skills_count": String(task.skills.count),
                "allowed_tools_count": String(task.resolvedAllowedTools.count)
            ])
        }

        // Collect in-flight @MainActor tasks so we can drain them before setting
        // final status. Without this, fire-and-forget Task blocks race with the
        // post-process code that reads task.tokensUsed, task.costUSD, etc.
        let pendingEvents = PendingTaskCollector()

        let result = await runClaudeProcess(
            prompt: prompt,
            task: task,
            workspacePath: executionPath,
            onLine: { line in
                // Parse each JSON line into structured events
                for parsed in StreamEventParser.parseAll(line: line) {
                    let t = Task { @MainActor [weak self] in
                        guard self != nil else { return }

                        switch parsed {
                    case .thinking(let text):
                        let event = TaskEvent(task: task, type: "agent.thinking", payload: text, run: run)
                        modelContext.insert(event)

                    case .text(let text):
                        run.output += text
                        let event = TaskEvent(task: task, type: "agent.response", payload: text, run: run)
                        modelContext.insert(event)

                    case .toolUse(let name, _, _):
                        let event = TaskEvent(task: task, type: "tool.use", payload: "Using tool: \(name)", run: run)
                        modelContext.insert(event)

                        // Capture file changes from Write/Edit tool uses
                        if let fileChange = StreamEventParser.extractFileChange(from: parsed) {
                            let stored = StoredFileChange(from: fileChange)
                            run.appendFileChange(stored)

                            // Create Artifact record with version increment
                            let existingVersion = task.artifacts
                                .filter { $0.path == fileChange.path }
                                .map(\.version)
                                .max() ?? 0
                            let artifact = Artifact(
                                task: task,
                                type: fileChange.changeType.rawValue,
                                path: fileChange.path,
                                version: existingVersion + 1
                            )
                            modelContext.insert(artifact)
                        }

                    case .toolResult(_, let content):
                        if !content.isEmpty {
                            let truncated = String(content.prefix(10000))
                            let event = TaskEvent(task: task, type: "tool.result", payload: truncated, run: run)
                            modelContext.insert(event)
                        }

                    case .result(let text, let costUSD, let totalInput, let totalOutput, let durationMs, let numTurns, let isError):
                        let totalTokens = totalInput + totalOutput
                        task.tokensUsed = totalTokens
                        run.tokensUsed = totalTokens
                        run.inputTokens = totalInput
                        run.outputTokens = totalOutput

                        if let cost = costUSD {
                            task.costUSD = cost
                            run.costUSD = cost
                        }

                        if let text = text, run.output.isEmpty {
                            run.output = text  // Fallback if no streaming text captured
                        }

                        let details = [
                            "tokens: \(totalTokens) (in: \(totalInput), out: \(totalOutput))",
                            costUSD.map { String(format: "cost: $%.4f", $0) },
                            durationMs.map { "duration: \($0)ms" },
                            numTurns.map { "turns: \($0)" }
                        ].compactMap { $0 }.joined(separator: " | ")

                        let event = TaskEvent(task: task, type: "task.stats", payload: details, run: run)
                        modelContext.insert(event)

                        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                            "tokens_total": String(totalTokens),
                            "tokens_input": String(totalInput),
                            "tokens_output": String(totalOutput),
                            "turns": numTurns.map(String.init) ?? "unknown",
                            "duration_ms": durationMs.map(String.init) ?? "unknown",
                            "has_error": String(isError)
                        ])
                        if isError {
                            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                                "reason": "agent_reported_error"
                            ], level: .warning)
                        }

                    case .systemInit(let model, let sessionId):
                        if let sid = sessionId {
                            task.sessionId = sid
                            AppLogger.audit(.workerSessionStarted, category: "Worker", taskID: task.id, fields: [
                                "session_id_prefix": String(sid.prefix(8))
                            ], level: .debug)
                        }
                        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                            "stream": "started",
                            "model": model ?? "unknown"
                        ])

                    // Agent Teams events
                    case .teammateStarted(let taskId, let name, let prompt):
                        let event = TaskEvent(task: task, type: "team.agent.started",
                            payload: "\(name) spawned: \(String(prompt.prefix(200)))",
                            run: run, agentName: name, agentId: taskId)
                        modelContext.insert(event)
                        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                            "team_event": "teammate_started",
                            "agent_id": taskId
                        ])

                    case .teammateCompleted(let taskId, let name):
                        let event = TaskEvent(task: task, type: "team.agent.completed",
                            payload: "\(name) finished",
                            run: run, agentName: name, agentId: taskId)
                        modelContext.insert(event)
                        AppLogger.audit(.taskCompleted, category: "Worker", taskID: task.id, fields: [
                            "team_event": "teammate_completed",
                            "agent_id": taskId
                        ])

                    case .teamCreated(let name, let description):
                        let event = TaskEvent(task: task, type: "team.created",
                            payload: "Team '\(name)' created: \(description)",
                            run: run, teamName: name)
                        modelContext.insert(event)
                        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                            "team_event": "team_created"
                        ])

                    case .teamDeleted(let name):
                        let event = TaskEvent(task: task, type: "team.deleted",
                            payload: "Team '\(name)' disbanded",
                            run: run, teamName: name)
                        modelContext.insert(event)
                        AppLogger.audit(.taskCompleted, category: "Worker", taskID: task.id, fields: [
                            "team_event": "team_deleted"
                        ])

                    case .teamMessage(let from, let to, let content):
                        let event = TaskEvent(task: task, type: "team.message",
                            payload: content,
                            run: run, agentName: from, agentId: to)
                        modelContext.insert(event)

                    case .permissionDenied(let tool, let reason):
                        let event = TaskEvent(task: task, type: "permission.denied",
                            payload: "Permission denied for tool: \(tool). \(String(reason.prefix(300)))",
                            run: run)
                        modelContext.insert(event)
                        AppLogger.audit(.workerPermissionDenied, category: "Worker", taskID: task.id, fields: [
                            "tool": tool
                        ], level: .warning)

                    case .unknown(let type):
                        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                            "event": "unknown_stream_event",
                            "event_type": type
                        ], level: .debug)
                    }

                    onEvent(parsed)
                }
                    pendingEvents.add(t)
                }
            }
        )

        // Drain all pending event-processing tasks before setting final status.
        // This ensures tokensUsed, costUSD, and all SwiftData inserts are complete.
        await pendingEvents.drainAll()

        // Final status
        run.completedAt = Date()
        run.exitCode = result.exitCode

        AppLogger.audit(.workerExited, category: "Worker", taskID: task.id, fields: [
            "exit_code": String(result.exitCode),
            "tokens_used": String(task.tokensUsed),
            "token_budget": String(task.tokenBudget)
        ], level: result.exitCode == 0 ? .info : .warning)

        if cancellationRequested || task.status == .cancelled {
            run.status = .cancelled
            run.stopReason = "cancelled"
            task.status = .cancelled
        } else if result.timedOut {
            run.status = .timeout
            run.stopReason = "timeout"
            task.status = .failed
            let event = TaskEvent(task: task, type: "error",
                                  payload: "Task idle timeout — no output for \(Int(timeoutSeconds))s. Process killed.", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: task.id, fields: [
                "phase": "run"
            ], level: .error)
        } else if result.maxTurnsExceeded {
            run.status = .budgetExceeded
            run.stopReason = "max_turns_reached"
            task.status = .budgetExceeded
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "Max turns reached (\(task.maxTurns)). Process killed.", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "reason": "max_turns_reached",
                "max_turns": String(task.maxTurns)
            ], level: .error)
        } else if result.budgetExceeded {
            run.status = .budgetExceeded
            run.stopReason = result.repetitionKilled ? "repetition_detected" : "max_budget_reached"
            task.status = .budgetExceeded
            let reason = result.repetitionKilled ? "Repetition loop detected" : "Token budget exceeded"
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). Process killed.", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "reason": result.repetitionKilled ? "repetition_detected" : "max_budget_reached",
                "tokens_used": String(task.tokensUsed),
                "token_budget": String(task.tokenBudget)
            ], level: .error)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"

            // Run validation based on strategy
            switch task.validationStrategy {
            case .manual:
                task.status = .completed
                let event = TaskEvent(task: task, type: "task.completed", payload: "Agent finished.", run: run)
                modelContext.insert(event)

            case .runTests:
                let testEvent = TaskEvent(task: task, type: "tool.use", payload: "Running validation tests...", run: run)
                modelContext.insert(testEvent)

                let testResult = await ValidationService.runTests(task: task)
                switch testResult {
                case .passed(let details):
                    task.status = .completed
                    let event = TaskEvent(task: task, type: "task.completed", payload: "Tests passed. \(String(details.prefix(300)))", run: run)
                    modelContext.insert(event)
                case .failed(let details):
                    task.status = .failed
                    let event = TaskEvent(task: task, type: "error", payload: "Tests failed:\n\(String(details.prefix(500)))", run: run)
                    modelContext.insert(event)
                case .error(let msg):
                    task.status = .pendingUser
                    let event = TaskEvent(task: task, type: "error", payload: "Validation error: \(msg). Needs manual review.", run: run)
                    modelContext.insert(event)
                }

            case .aiCheck:
                let checkEvent = TaskEvent(task: task, type: "tool.use", payload: "Running AI self-check...", run: run)
                modelContext.insert(checkEvent)

                let aiResult = await ValidationService.aiCheck(task: task, claudePath: claudePath, model: validationModel)
                switch aiResult {
                case .passed(let details):
                    task.status = .completed
                    let event = TaskEvent(task: task, type: "task.completed", payload: "AI check passed. \(String(details.prefix(300)))", run: run)
                    modelContext.insert(event)
                case .failed(let details):
                    task.status = .pendingUser
                    let event = TaskEvent(task: task, type: "error", payload: "AI check flagged issues:\n\(String(details.prefix(500)))", run: run)
                    modelContext.insert(event)
                case .error(let msg):
                    task.status = .pendingUser
                    let event = TaskEvent(task: task, type: "error", payload: "AI check error: \(msg). Needs manual review.", run: run)
                    modelContext.insert(event)
                }
            }
        } else {
            run.status = .failed
            run.stopReason = "failed"
            task.status = .failed
            let payload = enrichedFailurePayload(
                prefix: "Agent exited with code \(result.exitCode).",
                rawError: result.error
            )
            let event = TaskEvent(task: task, type: "error",
                                  payload: payload, run: run)
            modelContext.insert(event)
        }

        let folder = (try? task.ensureTaskFolder()) ?? ""
        if !folder.isEmpty {
            SessionHistoryManager.recordTurn(
                taskFolder: folder,
                taskTitle: task.title,
                turnMessage: task.goal,
                output: run.output,
                tokensUsed: run.tokensUsed,
                costUSD: run.costUSD,
                fileChanges: run.fileChanges,
                redactions: sensitiveRedactions(for: task),
                durationMs: run.completedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) }
            )
        }

        // Chain: auto-create follow-up task if configured
        if task.status == .completed,
           !task.chainedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let output = run.output
            let nextTask = AgentTask(
                title: String(task.chainedGoal.prefix(60)),
                goal: task.chainedGoal,
                workspace: task.workspace,
                tokenBudget: task.tokenBudget,
                model: task.model,
                isolationStrategy: task.isolationStrategy,
                validationStrategy: task.validationStrategy
            )
            nextTask.status = .queued
            nextTask.chainedFromID = task.id
            // Pipe previous output as input context
            if !output.isEmpty {
                nextTask.inputs = ["Previous task output (\(task.title)):\n\(String(output.prefix(5000)))"]
            }
            nextTask.skills = task.skills
            nextTask.captureSkillSnapshots()
            modelContext.insert(nextTask)

            let chainEvent = TaskEvent(task: task, type: "task.chained",
                payload: "Chained to next task: \(nextTask.title)")
            modelContext.insert(chainEvent)
            AppLogger.audit(.taskChained, category: "Worker", taskID: task.id, fields: [
                "next_task_id": nextTask.id.uuidString
            ])
        }

        // Auto-generate a short title after the first run if the title
        // is still just the truncated goal text (i.e. user never set one).
        if task.runs.count == 1,
           task.title == String(task.goal.prefix(60)),
           let ws = task.workspace {
            let goalText = task.goal
            let wsPath = ws.primaryPath
            let cPath = claudePath
            let taskRef = task
            Task.detached {
                if let generated = await SpecEngine.generateTitle(
                    goal: goalText,
                    workspacePath: wsPath,
                    claudePath: cPath
                ) {
                    await MainActor.run {
                        taskRef.title = generated
                        taskRef.updatedAt = Date()
                    }
                }
            }
        }

        // Cleanup isolation
        IsolationService.cleanup(task: task, executionPath: executionPath)

        // Compact events if they've grown too large
        Self.compactEvents(for: task, modelContext: modelContext)

        task.updatedAt = Date()
        if task.isTerminal {
            task.completedAt = Date()
        }

        // Auto-export workspace config so Import picks up tasks
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)

        isRunning = false
    }

    /// Continue an existing session with a follow-up message (HITL flow).
    @MainActor
    func continueSession(
        task: AgentTask,
        message: String,
        modelContext: ModelContext,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        guard !isRunning else {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "reason": "worker_already_running"
            ], level: .warning)
            return
        }
        isRunning = true
        cancellationRequested = false

        task.status = .running
        task.updatedAt = Date()

        let run = TaskRun(task: task)
        modelContext.insert(run)

        let userEvent = TaskEvent(task: task, type: "user.message", payload: message, run: run)
        modelContext.insert(userEvent)

        // Build a fresh prompt with session history instead of --resume (which resends full conversation).
        // This cuts input tokens by ~90% on follow-ups.
        let followUpPrompt = Self.buildFreshFollowUpPrompt(message: message, task: task)

        AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
            "mode": task.sessionId == nil ? "fresh_follow_up" : "session_follow_up",
            "message_length": String(message.count),
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])

        let pendingEvents = PendingTaskCollector()

        let result = await runClaudeProcess(
            prompt: followUpPrompt,
            task: task,
            workspacePath: task.codeWorkingDirectory,
            onLine: { line in
                for parsed in StreamEventParser.parseAll(line: line) {
                    let t = Task { @MainActor in
                        switch parsed {
                    case .thinking(let text):
                        let event = TaskEvent(task: task, type: "agent.thinking", payload: text, run: run)
                        modelContext.insert(event)
                    case .text(let text):
                        run.output += text
                        let event = TaskEvent(task: task, type: "agent.response", payload: text, run: run)
                        modelContext.insert(event)
                    case .toolUse(let name, _, _):
                        let event = TaskEvent(task: task, type: "tool.use", payload: "Using tool: \(name)", run: run)
                        modelContext.insert(event)
                        if let fileChange = StreamEventParser.extractFileChange(from: parsed) {
                            run.appendFileChange(StoredFileChange(from: fileChange))
                        }
                    case .result(_, let costUSD, let totalInput, let totalOutput, _, _, _):
                        let totalTokens = totalInput + totalOutput
                        task.tokensUsed += totalTokens
                        run.tokensUsed = totalTokens
                        run.inputTokens = totalInput
                        run.outputTokens = totalOutput
                        if let cost = costUSD {
                            task.costUSD += cost
                            run.costUSD = cost
                        }
                    case .systemInit(_, let sid):
                        if let sid { task.sessionId = sid }
                    case .toolResult(_, let content):
                        if !content.isEmpty {
                            let truncated = String(content.prefix(10000))
                            let event = TaskEvent(task: task, type: "tool.result", payload: truncated, run: run)
                            modelContext.insert(event)
                        }
                    case .permissionDenied(let tool, let reason):
                        let event = TaskEvent(task: task, type: "permission.denied",
                            payload: "Permission denied for tool: \(tool). \(String(reason.prefix(300)))",
                            run: run)
                        modelContext.insert(event)
                        AppLogger.audit(.workerPermissionDenied, category: "Worker", taskID: task.id, fields: [
                            "tool": tool
                        ], level: .warning)
                    default:
                        break
                    }
                    onEvent(parsed)
                }
                    pendingEvents.add(t)
                }
            }
        )

        // Drain all pending event-processing tasks before setting final status
        await pendingEvents.drainAll()

        run.completedAt = Date()
        run.exitCode = result.exitCode

        if cancellationRequested || task.status == .cancelled {
            run.status = .cancelled
            run.stopReason = "cancelled"
            task.status = .cancelled
        } else if result.timedOut {
            run.status = .timeout
            run.stopReason = "timeout"
            task.status = .failed
            let event = TaskEvent(task: task, type: "error",
                                  payload: "Resume idle timeout — no output for \(Int(timeoutSeconds))s. Process killed.", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: task.id, fields: [
                "phase": "resume"
            ], level: .error)
        } else if result.maxTurnsExceeded {
            run.status = .budgetExceeded
            run.stopReason = "max_turns_reached"
            task.status = .budgetExceeded
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "Max turns reached (\(task.maxTurns)) during resume. Process killed.", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "phase": "resume",
                "reason": "max_turns_reached",
                "max_turns": String(task.maxTurns)
            ], level: .error)
        } else if result.budgetExceeded {
            run.status = .budgetExceeded
            run.stopReason = result.repetitionKilled ? "repetition_detected" : "max_budget_reached"
            task.status = .budgetExceeded
            let reason = result.repetitionKilled ? "Repetition loop detected" : "Token budget exceeded"
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). Process killed.", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "phase": "resume",
                "reason": result.repetitionKilled ? "repetition_detected" : "max_budget_reached",
                "tokens_used": String(task.tokensUsed),
                "token_budget": String(task.tokenBudget)
            ], level: .error)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            task.status = .completed
            let event = TaskEvent(task: task, type: "task.completed", payload: "Follow-up completed.", run: run)
            modelContext.insert(event)
        } else {
            run.status = .failed
            run.stopReason = "failed"
            // Check for stale session ID (Claude exits non-zero when session not found)
            let isStaleSession = result.error?.contains("session") == true || result.error?.contains("not found") == true
            if isStaleSession {
                task.sessionId = nil  // Clear stale session so user can retry fresh
                let event = TaskEvent(task: task, type: "error",
                                      payload: "Session expired or not found. Session cleared — retry will start fresh.", run: run)
                modelContext.insert(event)
                AppLogger.audit(.workerSessionCleared, category: "Worker", taskID: task.id, fields: [
                    "reason": "stale_session"
                ], level: .warning)
            } else {
                let payload = enrichedFailurePayload(
                    prefix: "Follow-up failed (exit \(result.exitCode)).",
                    rawError: result.error
                )
                let event = TaskEvent(task: task, type: "error",
                                      payload: payload, run: run)
                modelContext.insert(event)
            }
            task.status = .failed
        }

        let folder = (try? task.ensureTaskFolder()) ?? ""
        if !folder.isEmpty {
            SessionHistoryManager.recordTurn(
                taskFolder: folder,
                taskTitle: task.title,
                turnMessage: message,
                output: run.output,
                tokensUsed: run.tokensUsed,
                costUSD: run.costUSD,
                fileChanges: run.fileChanges,
                redactions: sensitiveRedactions(for: task),
                durationMs: run.completedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) }
            )
        }

        // Compact events if they've grown too large
        Self.compactEvents(for: task, modelContext: modelContext)

        task.updatedAt = Date()

        // Auto-export workspace config so Import picks up follow-up runs
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)

        isRunning = false
    }

    @MainActor
    func cancel() {
        cancellationRequested = true
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
    }

    // MARK: - Private

    struct ProcessResult {
        let exitCode: Int
        let error: String?
        let budgetExceeded: Bool
        let timedOut: Bool
        let repetitionKilled: Bool
        let maxTurnsExceeded: Bool

        init(exitCode: Int, error: String? = nil, budgetExceeded: Bool = false, timedOut: Bool = false, repetitionKilled: Bool = false, maxTurnsExceeded: Bool = false) {
            self.exitCode = exitCode
            self.error = error
            self.budgetExceeded = budgetExceeded
            self.timedOut = timedOut
            self.repetitionKilled = repetitionKilled
            self.maxTurnsExceeded = maxTurnsExceeded
        }
    }

    // MARK: - Process Monitor (shared between run and resume)

    /// Encapsulates budget enforcement, repetition circuit breaker, and idle timeout
    /// so both `runClaudeProcess` and `runClaudeResume` share identical monitoring.
    nonisolated final class ProcessMonitor: @unchecked Sendable {
        let tokenBudget: Int
        let maxTurns: Int
        let maxRepetitions: Int
        let idleTimeoutSeconds: TimeInterval
        let taskID: UUID

        /// Lock protecting all mutable state below.
        /// Both `readabilityHandler` (background) and `terminationHandler` (background)
        /// and the watchdog thread read/write these fields concurrently.
        private let lock = NSLock()

        private var _estimatedTokens: Int = 0
        private var _turnCount: Int = 0
        private var _budgetExceeded: Bool = false
        private var _maxTurnsExceeded: Bool = false
        private var _timedOut: Bool = false
        private var _repetitionKilled: Bool = false

        private var lastEventSignature: String = ""
        private var repetitionCount: Int = 0
        private var lastActivityTime = Date()
        private var watchdogRunning = false

        // Thread-safe accessors for reading final state from terminationHandler
        var estimatedTokens: Int { lock.lock(); defer { lock.unlock() }; return _estimatedTokens }
        var turnCount: Int { lock.lock(); defer { lock.unlock() }; return _turnCount }
        var budgetExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _budgetExceeded }
        var maxTurnsExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _maxTurnsExceeded }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
        var repetitionKilled: Bool { lock.lock(); defer { lock.unlock() }; return _repetitionKilled }

        init(tokenBudget: Int, maxTurns: Int = 0, maxRepetitions: Int = 8, idleTimeoutSeconds: TimeInterval = 600, taskID: UUID = UUID()) {
            self.tokenBudget = tokenBudget
            self.maxTurns = maxTurns
            self.maxRepetitions = maxRepetitions
            self.idleTimeoutSeconds = idleTimeoutSeconds
            self.taskID = taskID
        }

        /// Called on each stream line. Returns true if the process should be killed.
        /// Thread-safe: called from readabilityHandler (background thread).
        func processEvent(_ parsed: ParsedEvent, process: Process?) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            // Record activity (inline to avoid nested lock)
            lastActivityTime = Date()

            // --- Turn counting (result events mark end of a turn) ---
            if case .result = parsed {
                _turnCount += 1
                if maxTurns > 0 && _turnCount >= maxTurns {
                    AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                        "reason": "max_turns_reached",
                        "turns": String(_turnCount),
                        "max_turns": String(maxTurns)
                    ], level: .error)
                    _maxTurnsExceeded = true
                    process?.terminate()
                    return true
                }
            }

            // --- Repetition circuit breaker ---
            let signature = Self.eventSignature(parsed)
            if signature == lastEventSignature {
                repetitionCount += 1
                if repetitionCount >= maxRepetitions {
                    AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                        "reason": "repetition_detected",
                        "repetition_count": String(repetitionCount)
                    ], level: .error)
                    _repetitionKilled = true
                    _budgetExceeded = true
                    process?.terminate()
                    return true
                }
            } else {
                lastEventSignature = signature
                repetitionCount = 1
            }

            // --- Budget enforcement ---
            // Exact count from result event
            if case .result(_, _, let totalInput, let totalOutput, _, _, _) = parsed {
                let totalTokens = totalInput + totalOutput
                if totalTokens > tokenBudget {
                    _budgetExceeded = true
                    process?.terminate()
                    return true
                }
            }

            // Mid-stream estimate
            switch parsed {
            case .text(let text):
                _estimatedTokens += max(1, text.count / 4)
            case .thinking(let text):
                _estimatedTokens += max(1, text.count / 4)
            case .toolUse:
                _estimatedTokens += 100
            case .toolResult:
                _estimatedTokens += 200
            case .teamMessage(_, _, let content):
                _estimatedTokens += max(50, content.count / 4)
            case .teammateStarted, .teammateCompleted, .teamCreated, .teamDeleted:
                _estimatedTokens += 50
            case .permissionDenied:
                _estimatedTokens += 50
            case .systemInit, .unknown:
                _estimatedTokens += 20
            case .result:
                break
            }

            if _estimatedTokens > tokenBudget {
                AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                    "reason": "estimated_budget_exceeded",
                    "estimated_tokens": String(_estimatedTokens),
                    "token_budget": String(tokenBudget)
                ], level: .error)
                _budgetExceeded = true
                process?.terminate()
                return true
            }

            return false
        }

        /// Mark activity (resets idle timer). Thread-safe.
        func recordActivity() {
            lock.lock()
            lastActivityTime = Date()
            lock.unlock()
        }

        /// Start the idle timeout watchdog on a background thread
        func startWatchdog(process: Process) {
            lock.lock()
            guard !watchdogRunning else { lock.unlock(); return }
            watchdogRunning = true
            lock.unlock()

            let checkInterval: TimeInterval = 30
            DispatchQueue.global().async { [weak self] in
                while true {
                    Thread.sleep(forTimeInterval: checkInterval)
                    guard let self, process.isRunning else { return }

                    self.lock.lock()
                    let idleDuration = Date().timeIntervalSince(self.lastActivityTime)
                    self.lock.unlock()

                    if idleDuration >= self.idleTimeoutSeconds {
                        AppLogger.audit(.workerTimeout, category: "Worker", taskID: self.taskID, fields: [
                            "idle_seconds": String(Int(idleDuration)),
                            "limit_seconds": String(Int(self.idleTimeoutSeconds))
                        ], level: .error)
                        self.lock.lock()
                        self._timedOut = true
                        self.lock.unlock()
                        process.terminate()
                        return
                    }
                }
            }
        }

        static func eventSignature(_ parsed: ParsedEvent) -> String {
            switch parsed {
            case .text(let t): return "text:\(t.prefix(80))"
            case .thinking(let t): return "think:\(t.prefix(80))"
            case .toolUse(let name, _, _): return "tool:\(name)"
            case .toolResult(let id, _): return "result:\(id)"
            case .result(let t, _, _, _, _, _, _): return "result:\(String((t ?? "").prefix(80)))"
            case .systemInit: return "init"
            case .teammateStarted(_, let name, _): return "teammate.start:\(name)"
            case .teammateCompleted(_, let name): return "teammate.done:\(name)"
            case .teamCreated(let name, _): return "team.created:\(name)"
            case .teamDeleted(let name): return "team.deleted:\(name)"
            case .teamMessage(let from, let to, _): return "team.msg:\(from)->\(to)"
            case .permissionDenied(let tool, _): return "perm.denied:\(tool)"
            case .unknown(let type): return "unknown:\(type)"
            }
        }
    }

    /// Build a follow-up message with full context so the resumed session
    /// has the same quality as the initial prompt.
    /// Build a fresh prompt for follow-ups that includes session history context inline.
    /// This avoids --resume which resends the FULL prior conversation (500K+ tokens).
    /// Instead we include compact summaries, all final answers, and generated file paths.
    private static func buildFreshFollowUpPrompt(message: String, task: AgentTask) -> String {
        var parts: [String] = []

        // 1. Task context (goal + workspace)
        parts.append("You are continuing work on a task. Here is the original goal:")
        parts.append("Goal: \(task.goal)")

        // 2. Session history — compact summaries of all prior turns
        let folder = task.taskFolder
        if !folder.isEmpty {
            let historyPath = SessionHistoryManager.historyPath(taskFolder: folder)
            if let history = try? String(contentsOfFile: historyPath, encoding: .utf8) {
                let trimmed = String(history.suffix(4000))
                parts.append("Session History (prior turns):\n\(trimmed)")
            }
        }

        // 3. All completed run outputs — the agent needs its own final answers
        let sortedRuns = task.runs.sorted { $0.startedAt < $1.startedAt }
        if !sortedRuns.isEmpty {
            var answersBlock = "Previous responses (your final answers from each turn):"
            for (i, run) in sortedRuns.enumerated() where !run.output.isEmpty {
                let turnLabel = "Turn \(i + 1)"
                // Last run gets more space, earlier runs get compact summaries
                let maxLen = (i == sortedRuns.count - 1) ? 3000 : 1000
                let snippet = run.output.count > maxLen
                    ? String(run.output.suffix(maxLen))
                    : run.output
                answersBlock += "\n\n--- \(turnLabel) ---\n\(snippet)"
            }
            parts.append(answersBlock)
        }

        // 4. Files changed across all runs
        let allChanges = task.runs.flatMap { $0.fileChanges }
        if !allChanges.isEmpty {
            let uniquePaths = Array(Set(allChanges.map { $0.path })).sorted().suffix(20)
            let changeList = uniquePaths.map { path -> String in
                let lastChange = allChanges.last { $0.path == path }
                let icon = lastChange?.changeType == "Write" ? "+" : "~"
                return "[\(icon)] \(path)"
            }.joined(separator: "\n")
            parts.append("Files modified in this task:\n\(changeList)")
        }

        // 5. Generated files in the task folder — artifacts, reports, scripts
        if !folder.isEmpty {
            let taskFiles = Self.listTaskFolderFiles(folder)
            if !taskFiles.isEmpty {
                parts.append("Generated files in task folder (\(folder)):\n\(taskFiles.joined(separator: "\n"))\nYou can read these files if needed for context.")
            }
        }

        // 6. Workspace/SSH/tools context (reuse existing logic)
        let contextLine = buildFollowUpMessage(message: "", task: task)
        if contextLine != "" {
            if let bracketEnd = contextLine.range(of: "]\n\n") {
                parts.append(String(contextLine[contextLine.startIndex...bracketEnd.lowerBound]))
            }
        }

        // 6b. Connector context — critical for follow-ups so the agent uses correct URLs/credentials
        let resolvedEnv = task.resolvedEnvironmentVariables
        let connectorDescs = task.allConnectors.map { conn -> String in
            var desc = "[\(conn.name)] \(conn.serviceType)"
            if !conn.baseURL.isEmpty { desc += " — Base URL: \(conn.baseURL)" }
            let availableKeys = conn.credentialKeys.filter { resolvedEnv[$0] != nil }
            if !availableKeys.isEmpty {
                desc += " — Credentials in env: \(availableKeys.joined(separator: ", "))"
            }
            return desc
        }
        if !connectorDescs.isEmpty {
            parts.append("Available Connectors (use these URLs, NOT any URLs from prior conversation):\n" + connectorDescs.joined(separator: "\n") + "\n\nIMPORTANT: Use Bash with curl to call APIs using env var credentials. Do NOT use WebFetch for authenticated APIs.")
        }

        // 7. Workspace memories — persistent facts the user has saved
        if let memories = task.workspace?.memories, !memories.isEmpty {
            let memoriesBlock = """
            YOUR MEMORIES (saved by the user for this workspace — these ARE your persistent memories, do NOT look for memory files on disk):
            \(memories.map { "- \($0)" }.joined(separator: "\n"))
            When the user asks about your memories, report these items. Do not check ~/.claude/ or any file-based memory system.
            """
            parts.append(memoriesBlock)
        }

        // 8. The actual user message
        parts.append("User's follow-up request:\n\(message)")

        return parts.joined(separator: "\n\n")
    }

    /// List files in the task folder (excluding internal outputs/ dir) for context.
    private static func listTaskFolderFiles(_ folder: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let rel = url.path.replacingOccurrences(of: folder + "/", with: "")
            // Skip the outputs/ subdirectory (those are full turn dumps, too large)
            if rel.hasPrefix("outputs/") { continue }
            // Skip session_history.md (already included above)
            if rel == "session_history.md" { continue }
            files.append("- \(rel) (\(url.path))")
            if files.count >= 30 { break }
        }
        return files
    }

    private func sensitiveRedactions(for task: AgentTask) -> [String] {
        Array(Set(
            task.resolvedEnvironmentVariables.values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
    }

    private static func buildFollowUpMessage(message: String, task: AgentTask) -> String {
        var contextParts: [String] = []

        if let ws = task.workspace {
            // SSH connection scope
            let connections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
            if let conn = connections.first, !conn.remotePath.isEmpty {
                contextParts.append("Remote server: ssh \(conn.configAlias.isEmpty ? conn.sshTarget : conn.configAlias) — remote path: \(conn.remotePath)")
            }

            // Additional workspace paths
            if !ws.additionalPaths.isEmpty {
                let paths = ws.additionalPaths.map { "\((($0 as NSString).lastPathComponent)): \($0)" }.joined(separator: ", ")
                contextParts.append("Additional workspace folders: \(paths)")
            }

            // Workspace instructions
            if !ws.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contextParts.append("Workspace: \(String(ws.instructions.prefix(300)))")
            }
        }

        // Skill behavior instructions
        let behaviorBlock = task.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            contextParts.append("Skills: \(String(behaviorBlock.prefix(500)))")
        }

        // Recent file changes — where the agent was working
        if let lastRun = task.runs.sorted(by: { $0.startedAt > $1.startedAt }).first {
            let recentPaths = lastRun.fileChanges.suffix(5).map { $0.path }
            if !recentPaths.isEmpty {
                let dirs = Set(recentPaths.compactMap { path -> String? in
                    let url = URL(fileURLWithPath: path)
                    let dir = url.deletingLastPathComponent().path
                    return dir.isEmpty ? nil : dir
                })
                if !dirs.isEmpty {
                    contextParts.append("You were working in: \(dirs.joined(separator: ", "))")
                }
            }
        }

        // Session history file for context recovery
        let folder = task.taskFolder
        if !folder.isEmpty {
            let historyPath = SessionHistoryManager.historyPath(taskFolder: folder)
            if FileManager.default.fileExists(atPath: historyPath) {
                contextParts.append("Session history: \(historyPath)")
            }
        }

        // Global tools
        let readfilePath = NSHomeDirectory() + "/.astra/tools/readfile"
        if FileManager.default.isExecutableFile(atPath: readfilePath) {
            contextParts.append("Document reader: `readfile <path>` reads .docx/.pdf/.xlsx/.pptx and more")
        }

        if contextParts.isEmpty {
            return message
        }

        return "[Context: \(contextParts.joined(separator: " | "))]\n\n\(message)"
    }

    // MARK: - Event Compaction

    /// Compact events for a task when they exceed the threshold.
    /// Keeps the most recent `keepCount` events and replaces older ones
    /// with a single summary event.
    static let compactionThreshold = 200
    static let compactionKeepCount = 50

    @MainActor
    static func compactEvents(for task: AgentTask, modelContext: ModelContext) {
        let events = task.events.sorted { $0.timestamp < $1.timestamp }
        guard events.count > compactionThreshold else { return }

        let cutoff = events.count - compactionKeepCount
        let toCompact = Array(events.prefix(cutoff))

        // Build summary
        var typeCounts: [String: Int] = [:]
        for event in toCompact {
            typeCounts[event.type, default: 0] += 1
        }

        let summary = typeCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")

        let summaryEvent = TaskEvent(
            task: task,
            type: "activity.compacted",
            payload: "Compacted \(toCompact.count) earlier events. Breakdown: \(summary)"
        )
        // Set timestamp to just before the oldest kept event
        if let firstKept = events.dropFirst(cutoff).first {
            summaryEvent.timestamp = firstKept.timestamp.addingTimeInterval(-1)
        }
        modelContext.insert(summaryEvent)

        // Delete compacted events
        for event in toCompact {
            modelContext.delete(event)
        }

        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "event": "activity_compacted",
            "compacted_count": String(toCompact.count),
            "kept_count": String(compactionKeepCount)
        ])
    }

    static func ensureSubAgentPermissions(at workspacePath: String, policy: PermissionPolicy, allowedTools: [String]) {
        let claudeDir = (workspacePath as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")

        if FileManager.default.fileExists(atPath: settingsPath) { return }

        let perms = policy.subAgentPermissions(allowedTools: allowedTools)
        guard !perms.isEmpty else { return }

        try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        let settings: [String: Any] = ["permissions": perms[0]]

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
            AppLogger.audit(.workerStarted, category: "Worker", fields: [
                "event": "subagent_permissions_created",
                "policy": policy.rawValue
            ])
        }
    }

    func buildPrompt(for task: AgentTask) -> String {
        var parts: [String] = []

        // Inject workspace instructions if set
        if let instructions = task.workspace?.instructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Workspace Context:\n\(instructions)")
        }

        // Inject workspace memories — persistent facts the user has saved
        if let memories = task.workspace?.memories, !memories.isEmpty {
            let memoriesBlock = """
            YOUR MEMORIES (saved by the user for this workspace — these ARE your persistent memories, do NOT look for memory files on disk):
            \(memories.map { "- \($0)" }.joined(separator: "\n"))
            When the user asks about your memories, report these items. Do not check ~/.claude/ or any file-based memory system.
            """
            parts.append(memoriesBlock)
        }

        // Inject recent task summaries for continuity
        if let ws = task.workspace {
            let recentTasks = ws.tasks
                .filter { $0.id != task.id && $0.isTerminal }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .prefix(3)

            if !recentTasks.isEmpty {
                var summaryBlock = "Recent tasks in this workspace (for context):"
                for t in recentTasks {
                    let status = t.status.rawValue
                    let output = t.runs.last?.output ?? ""
                    let summary = output.isEmpty ? "(no output)" : String(output.prefix(200))
                    summaryBlock += "\n- [\(status)] \(t.title): \(summary)"
                }
                parts.append(summaryBlock)
            }
        }

        // Inject SSH connections if available
        if let ws = task.workspace {
            let connections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
            if connections.count == 1, let conn = connections.first {
                // Single connection — make it the default context
                let alias = conn.configAlias.isEmpty ? conn.sshTarget : conn.configAlias
                var sshBlock = "Remote Server: This workspace is connected to a remote server via SSH."
                sshBlock += "\n- Name: \(conn.displayLabel)"
                sshBlock += "\n- Connect with: ssh \(alias)"
                sshBlock += "\n- Remote path: \(conn.remotePath)"
                sshBlock += "\nWhen the user says \"the server\", \"the remote\", \"this connection\", or \"it\" in the context of SSH, they mean this server."
                sshBlock += "\nTo run commands: ssh \(alias) '<command>'"
                sshBlock += "\nTo run commands in a specific directory: ssh \(alias) 'cd \(conn.remotePath) && <command>'"
                parts.append(sshBlock)
            } else if connections.count > 1 {
                var sshBlock = "Available SSH Connections (use these to access remote servers via Bash with ssh):"
                for conn in connections {
                    let alias = conn.configAlias.isEmpty ? conn.sshTarget : conn.configAlias
                    sshBlock += "\n- \(conn.displayLabel): ssh \(alias) (remote path: \(conn.remotePath))"
                    if !conn.configAlias.isEmpty {
                        sshBlock += " [uses ~/.ssh/config alias]"
                    }
                }
                sshBlock += "\nTo run commands on a remote server, use: ssh <alias> '<command>'"
                parts.append(sshBlock)
            }
        }

        // Inject workspace additional paths
        if let ws = task.workspace, !ws.additionalPaths.isEmpty {
            let codeDir = task.codeWorkingDirectory
            if codeDir != task.effectiveWorkspacePath {
                parts.append("WORKING DIRECTORY: Your process is running in \(codeDir). This is the primary code directory for this workspace. All relative paths resolve from here.")
            }
            if ws.additionalPaths.count > 1 {
                let extras = ws.additionalPaths.dropFirst().map { path -> String in
                    let name = (path as NSString).lastPathComponent
                    return "- \(name): \(path)"
                }.joined(separator: "\n")
                parts.append("Additional Workspace Folders:\n\(extras)")
            }
        }

        // Task-specific output folder
        let taskDir = task.taskFolder
        if !taskDir.isEmpty {
            parts.append("Task Output Folder: \(taskDir)\nSave any output files, reports, or artifacts to this folder. The workspace root is available for reading shared files.")
        }

        parts.append("Goal: \(task.goal)")

        if !task.inputs.isEmpty {
            var contextParts: [String] = []
            for input in task.inputs {
                // If it looks like a file path and exists, include the content
                if input.hasPrefix("/") || input.hasPrefix("~"),
                   let content = try? String(contentsOfFile: (input as NSString).expandingTildeInPath, encoding: .utf8) {
                    let truncated = content.count > 5000 ? String(content.prefix(5000)) + "\n... (truncated)" : content
                    contextParts.append("File: \(input)\n```\n\(truncated)\n```")
                } else {
                    // Treat as inline context snippet
                    contextParts.append("Context: \(input)")
                }
            }
            parts.append("Context/Inputs:\n" + contextParts.joined(separator: "\n\n"))
        }

        if !task.constraints.isEmpty {
            parts.append("Constraints:\n" + task.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !task.acceptanceCriteria.isEmpty {
            parts.append("Acceptance Criteria:\n" + task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }

        let behaviorBlock = task.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            parts.append("Behavioral Instructions (from Skills):\n\(behaviorBlock)")
        }

        // Connector context: tell agent about available services and their credentials
        let resolvedEnv = task.resolvedEnvironmentVariables
        let connectorDescriptions = task.allConnectors.map { conn in
            var desc = "[\(conn.name)] \(conn.serviceType) — \(conn.connectorDescription)"
            if !conn.baseURL.isEmpty { desc += "\n  Base URL: \(conn.baseURL)" }
            if !conn.configKeys.isEmpty {
                let configs = zip(conn.configKeys, conn.configValues)
                    .map { "\($0): \($1)" }
                    .joined(separator: ", ")
                desc += "\n  Config: \(configs)"
            }
            if !conn.credentialKeys.isEmpty {
                let availableKeys = conn.credentialKeys.filter { resolvedEnv[$0] != nil }
                let missingKeys = conn.credentialKeys.filter { resolvedEnv[$0] == nil }
                if !availableKeys.isEmpty {
                    desc += "\n  Credentials ALREADY SET in your environment: \(availableKeys.joined(separator: ", ")) — use os.environ[\"KEY\"] directly, do NOT ask the user for these"
                }
                if !missingKeys.isEmpty {
                    desc += "\n  Credentials NOT configured (ask user to fill them in workspace settings): \(missingKeys.joined(separator: ", "))"
                }
            }
            desc += "\n  Auth: \(conn.authMethod)"
            if !conn.notes.isEmpty { desc += "\n  Notes: \(conn.notes)" }
            return desc
        }
        if !connectorDescriptions.isEmpty {
            parts.append("""
            Available Connectors (credentials are pre-loaded into your process environment — use them directly, never ask the user to provide them again):
            \(connectorDescriptions.joined(separator: "\n\n"))

            IMPORTANT: To call authenticated APIs, use Bash with curl/python and the env var tokens — NOT WebFetch. \
            WebFetch cannot handle SSO, session cookies, or token-based auth headers. Example:
              curl -X POST "$BASE_URL/api/" -d "token=$API_TOKEN&content=record&format=json"
            Or in Python: os.environ["TOKEN_KEY"] to read the credential.
            """)
        }

        // Local tool context — CLI/script tools run via Bash, MCP tools are native
        let allLocalTools = task.allLocalTools.filter { !$0.command.isEmpty }
        let cliTools = allLocalTools.filter { $0.toolType != "mcp" }
        let mcpTools = allLocalTools.filter { $0.toolType == "mcp" }

        if !cliTools.isEmpty {
            let descriptions = cliTools.map { tool in
                "- \(tool.name): `\(tool.displayCommand)` — \(tool.toolDescription)"
            }.joined(separator: "\n")
            parts.append("Available CLI/Script Tools (run these using the Bash tool):\n\(descriptions)\n\nTo use these, call them via the Bash tool. Example: Bash(`\(cliTools[0].displayCommand)`)")
        }
        if !mcpTools.isEmpty {
            let descriptions = mcpTools.map { tool in
                "- \(tool.name): \(tool.command) — \(tool.toolDescription)"
            }.joined(separator: "\n")
            parts.append("Available MCP Tools (use directly by tool name):\n" + descriptions)
        }

        // Global tools available to all agents
        let readfilePath = NSHomeDirectory() + "/.astra/tools/readfile"
        if FileManager.default.isExecutableFile(atPath: readfilePath) {
            parts.append("""
            Document Reader Tool: You have a `readfile` command available for reading documents.
            Usage: `readfile <path>` — reads .docx, .pdf, .rtf, .xlsx, .pptx, .csv, .odt, .html, and more.
            For directories: `readfile <folder>` — lists contents recursively.
            Add `--metadata` for file metadata. Run via Bash tool: `\(readfilePath) <path>`
            """)
        }

        // Agent Teams: prepend team instructions when enabled
        if task.useAgentTeam {
            var teamBlock = "Create an agent team with \(task.teamSize) teammates to accomplish the goal below. Coordinate them to work in parallel and synthesize their results."
            if !task.teamInstructions.isEmpty {
                teamBlock += "\n\(task.teamInstructions)"
            }
            parts.insert(teamBlock, at: 0)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Model used for AI validation checks
    var validationModel: String = "claude-haiku-4-5-20251001"

    /// Maximum execution time in seconds (10 minutes default)
    var timeoutSeconds: TimeInterval = 600

    /// Review and planning happen in the composer flow before a task is created.
    /// Once work is running as an AgentTask, execution is always autonomous.
    var skipPermissions: Bool = true
    var permissionPolicy: PermissionPolicy = .autonomous

    private func appendPermissionArguments(to args: inout [String]) {
        args += permissionPolicy.cliArguments
    }

    private func runClaudeProcess(
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        onLine: @escaping (String) -> Void
    ) async -> ProcessResult {
        let model = task.model
        // Capture env vars on the calling (main) actor before entering the continuation,
        // since resolvedEnvironmentVariables may need SwiftData model context access.
        let taskEnv = task.resolvedEnvironmentVariables
        let allowed = task.resolvedClaudeAllowedTools
        // 0 = unlimited; auto-scale budget for team tasks
        let baseBudget = task.tokenBudget
        let tokenBudget: Int
        if baseBudget == 0 {
            tokenBudget = Int.max  // Unlimited
        } else if task.useAgentTeam {
            tokenBudget = baseBudget * max(2, task.teamSize)  // Scale with team size
            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "event": "team_budget_scaled",
                "base_budget": String(baseBudget),
                "team_size": String(max(2, task.teamSize)),
                "token_budget": String(tokenBudget)
            ])
        } else {
            tokenBudget = baseBudget
        }
        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var hasResumed = false
            let resumeOnce: (ProcessResult) -> Void = { result in
                resumeLock.lock()
                guard !hasResumed else { resumeLock.unlock(); return }
                hasResumed = true
                resumeLock.unlock()
                continuation.resume(returning: result)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)

            var args = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose"]
            appendPermissionArguments(to: &args)
            Self.ensureSubAgentPermissions(at: workspacePath, policy: permissionPolicy, allowedTools: allowed)
            // Limit turns at the CLI level if the user configured it
            if task.maxTurns > 0 {
                args += ["--max-turns", String(task.maxTurns)]
            }
            if !allowed.isEmpty {
                args += ["--allowedTools"] + allowed
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:\(NSHomeDirectory())/.astra/tools"
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
            for (key, value) in taskEnv {
                env[key] = value
            }
            if !taskEnv.isEmpty {
                AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                    "phase": "run",
                    "env_count": String(taskEnv.count)
                ])
            }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let errorOutput = LockedBuffer()
            let lineBuffer = LockedBuffer()

            let monitor = ProcessMonitor(
                tokenBudget: tokenBudget,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: self.timeoutSeconds,
                taskID: task.id
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }

                lineBuffer.append(chunk)
                var buf = lineBuffer.value
                while let newlineIndex = buf.firstIndex(of: "\n") {
                    let line = String(buf[buf.startIndex..<newlineIndex])
                    buf = String(buf[buf.index(after: newlineIndex)...])

                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        onLine(line)

                        for parsed in StreamEventParser.parseAll(line: line) {
                            let _ = monitor.processEvent(parsed, process: process)
                        }
                    }
                }
                lineBuffer.value = buf
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    errorOutput.append(str)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = lineBuffer.value
                if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                    onLine(remaining)
                }
                let errStr = errorOutput.value
                resumeOnce(ProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    error: errStr.isEmpty ? nil : errStr,
                    budgetExceeded: monitor.budgetExceeded,
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded
                ))
            }

            self.currentProcess = process

            do {
                try process.run()
            } catch {
                resumeOnce(ProcessResult(exitCode: -1, error: error.localizedDescription))
                return
            }

            monitor.startWatchdog(process: process)
        }
    }

    /// Run claude with --resume to continue an existing session.
    /// Now includes budget enforcement, repetition circuit breaker, and idle timeout
    /// via the shared ProcessMonitor — matching the protections in runClaudeProcess.
    private func runClaudeResume(
        sessionId: String,
        message: String,
        task: AgentTask,
        workspacePath: String,
        onLine: @escaping (String) -> Void
    ) async -> ProcessResult {
        // Pre-capture env vars and tools on calling actor before entering continuation
        let taskEnv = task.resolvedEnvironmentVariables
        let allowed = task.resolvedClaudeAllowedTools
        // Calculate remaining budget for this resume
        let baseBudget = task.tokenBudget
        let remainingBudget: Int
        if baseBudget == 0 {
            remainingBudget = Int.max
        } else {
            remainingBudget = max(1000, baseBudget - task.tokensUsed) // at least 1k to do anything useful
        }

        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var hasResumed = false
            let resumeOnce: (ProcessResult) -> Void = { result in
                resumeLock.lock()
                guard !hasResumed else { resumeLock.unlock(); return }
                hasResumed = true
                resumeLock.unlock()
                continuation.resume(returning: result)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)

            var args = ["-p", message, "--resume", sessionId, "--output-format", "stream-json", "--verbose"]
            appendPermissionArguments(to: &args)
            Self.ensureSubAgentPermissions(at: workspacePath, policy: permissionPolicy, allowedTools: allowed)
            // Limit turns at the CLI level if the user configured it
            if task.maxTurns > 0 {
                args += ["--max-turns", String(task.maxTurns)]
            }
            if !allowed.isEmpty {
                args += ["--allowedTools"] + allowed
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:\(NSHomeDirectory())/.astra/tools"
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
            for (key, value) in taskEnv {
                env[key] = value
            }
            if !taskEnv.isEmpty {
                AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                    "phase": "resume",
                    "env_count": String(taskEnv.count)
                ])
            }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let errorOutput = LockedBuffer()
            let lineBuffer = LockedBuffer()

            let monitor = ProcessMonitor(
                tokenBudget: remainingBudget,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: self.timeoutSeconds,
                taskID: task.id
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }

                lineBuffer.append(chunk)
                var buf = lineBuffer.value
                while let newlineIndex = buf.firstIndex(of: "\n") {
                    let line = String(buf[buf.startIndex..<newlineIndex])
                    buf = String(buf[buf.index(after: newlineIndex)...])
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        onLine(line)

                        for parsed in StreamEventParser.parseAll(line: line) {
                            let _ = monitor.processEvent(parsed, process: process)
                        }
                    }
                }
                lineBuffer.value = buf
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    errorOutput.append(str)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = lineBuffer.value
                if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                    onLine(remaining)
                }
                let errStr = errorOutput.value
                resumeOnce(ProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    error: errStr.isEmpty ? nil : errStr,
                    budgetExceeded: monitor.budgetExceeded,
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded
                ))
            }

            self.currentProcess = process

            do {
                try process.run()
            } catch {
                resumeOnce(ProcessResult(exitCode: -1, error: error.localizedDescription))
            }

            monitor.startWatchdog(process: process)
        }
    }

    // MARK: - Error enrichment

    /// Format a failure payload, folding in actionable install guidance
    /// when stderr looks like "command not found: X". The prefix carries
    /// the generic worker context ("Agent exited with code N.") and
    /// `rawError` is the stderr blob from the run.
    ///
    /// On no-match, returns the concatenation of prefix + rawError (the
    /// old behavior), so this is a strictly additive improvement.
    @MainActor
    private func enrichedFailurePayload(prefix: String, rawError: String?) -> String {
        let raw = rawError ?? ""
        let knownPrereqs = PluginCatalog.builtInPackages.flatMap { $0.prerequisites }
        if let enrichment = ClaudeErrorEnricher.enrich(
            stderr: raw,
            knownPrerequisites: knownPrereqs
        ) {
            AppLogger.audit(.workerExited, category: "Worker", fields: [
                "enriched": "true",
                "missing_binary": enrichment.binary
            ], level: .warning)
            // Surface the enriched message first; keep the raw stderr tail
            // for power users who want the gory details.
            let tail = raw.isEmpty ? "" : "\n\nRaw error:\n\(raw)"
            return "\(prefix) \(enrichment.displayMessage)\(tail)"
        }
        return "\(prefix) \(raw)"
    }
}
