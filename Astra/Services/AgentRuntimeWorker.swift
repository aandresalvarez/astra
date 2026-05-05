import Foundation
import SwiftData
import ASTRACore

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
final class AgentRuntimeWorker {
    private(set) var isRunning = false
    private var cancellationRequested = false
    private var runtimeConfiguration = AgentRuntimeConfiguration()
    private let processRunner = AgentRuntimeProcessRunner()

    /// Path to the Claude CLI. Auto-detected or set manually.
    var claudePath: String {
        get { runtimeConfiguration.claudePath }
        set { runtimeConfiguration.claudePath = newValue }
    }

    var copilotPath: String {
        get { runtimeConfiguration.copilotPath }
        set { runtimeConfiguration.copilotPath = newValue }
    }

    var copilotHome: String {
        get { runtimeConfiguration.copilotHome }
        set { runtimeConfiguration.copilotHome = newValue }
    }

    var defaultRuntimeID: AgentRuntimeID {
        get { runtimeConfiguration.defaultRuntimeID }
        set { runtimeConfiguration.defaultRuntimeID = newValue }
    }

    @MainActor
    init() {
        AppLogger.audit(.workerStarted, category: "Worker", fields: [
            "phase": "initialized",
            "claude_path_configured": String(!claudePath.isEmpty)
        ], level: .debug)
    }

    /// Execute a task with its configured agent runtime.
    @MainActor
    func execute(
        task: AgentTask,
        modelContext: ModelContext,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        if runtimeConfiguration.selectedRuntime(for: task) == .copilotCLI {
            await executeCopilot(task: task, modelContext: modelContext, onEvent: onEvent)
            return
        }

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
        task.markRead()

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
            task.markUnreadForCurrentStatus(at: task.updatedAt)
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
            task.markUnreadForCurrentStatus(at: task.updatedAt)
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
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, type: "error",
                payload: "Workspace isolation failed: \(error.localizedDescription)", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        let prompt = buildPrompt(for: task)
        Self.logCapabilityResolution(for: task, runtime: .claudeCode, phase: "run")
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
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
        )

        let result = await processRunner.runClaudeProcess(
            prompt: prompt,
            task: task,
            workspacePath: executionPath,
            claudePath: claudePath,
            permissionPolicy: permissionPolicy,
            timeoutSeconds: timeoutSeconds,
            onLine: { line in
                // Parse each JSON line into structured events
                for parsed in StreamEventParser.parseAll(line: line) {
                    for filtered in eventPipeline.process(parsed) {
                        let t = Task { @MainActor [weak self] in
                            guard self != nil else { return }

                            AgentEventRecorder.recordClaudeRunEvent(filtered, to: task, run: run, modelContext: modelContext)
                            onEvent(filtered)
                        }
                        pendingEvents.add(t)
                    }
                }
            }
        )

        for parsed in eventPipeline.flushParsedEvents() {
            let t = Task { @MainActor [weak self] in
                guard self != nil else { return }

                AgentEventRecorder.recordClaudeRunEvent(parsed, to: task, run: run, modelContext: modelContext)
                onEvent(parsed)
            }
            pendingEvents.add(t)
        }

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
                redactions: AgentSensitiveRedactions.values(for: task),
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
            nextTask.runtimeID = task.runtimeID
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

        let finishedAt = Date()
        task.updatedAt = finishedAt
        if task.isTerminal {
            task.completedAt = finishedAt
        }
        task.markUnreadForCurrentStatus(at: finishedAt)

        // Auto-export workspace config so Import picks up tasks
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: Self.runPersistenceFields(task: task, run: run, phase: "run")
        )

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
        if runtimeConfiguration.selectedRuntime(for: task) == .copilotCLI {
            let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: message, task: task)
            AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
                "mode": "fresh_follow_up",
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "message_length": String(message.count),
                "prompt_chars": String(prompt.count),
                "history_run_count": String(task.runs.count),
                "history_output_chars": String(task.runs.reduce(0) { $0 + $1.output.count }),
                "has_session_id": String(task.sessionId != nil),
                "workspace_id": task.workspace?.id.uuidString ?? "none"
            ])
            await executeCopilot(
                task: task,
                modelContext: modelContext,
                onEvent: onEvent,
                promptOverride: prompt,
                startEventType: "user.message",
                startEventPayload: message,
                auditPhase: "resume"
            )
            return
        }

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
        task.markRead()

        let run = TaskRun(task: task)
        modelContext.insert(run)

        let userEvent = TaskEvent(task: task, type: "user.message", payload: message, run: run)
        modelContext.insert(userEvent)

        // Build a fresh prompt with session history instead of --resume (which resends full conversation).
        // This cuts input tokens by ~90% on follow-ups.
        let followUpPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: message, task: task)

        AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
            "mode": task.sessionId == nil ? "fresh_follow_up" : "session_follow_up",
            "runtime": AgentRuntimeID.claudeCode.rawValue,
            "message_length": String(message.count),
            "prompt_chars": String(followUpPrompt.count),
            "history_run_count": String(task.runs.count),
            "history_output_chars": String(task.runs.reduce(0) { $0 + $1.output.count }),
            "has_session_id": String(task.sessionId != nil),
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])

        let pendingEvents = PendingTaskCollector()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
        )

        let result = await processRunner.runClaudeProcess(
            prompt: followUpPrompt,
            task: task,
            workspacePath: task.codeWorkingDirectory,
            claudePath: claudePath,
            permissionPolicy: permissionPolicy,
            timeoutSeconds: timeoutSeconds,
            onLine: { line in
                for parsed in StreamEventParser.parseAll(line: line) {
                    for filtered in eventPipeline.process(parsed) {
                        let t = Task { @MainActor in
                            AgentEventRecorder.recordClaudeFollowUpEvent(filtered, to: task, run: run, modelContext: modelContext)
                            onEvent(filtered)
                        }
                        pendingEvents.add(t)
                    }
                }
            }
        )

        for parsed in eventPipeline.flushParsedEvents() {
            let t = Task { @MainActor in
                AgentEventRecorder.recordClaudeFollowUpEvent(parsed, to: task, run: run, modelContext: modelContext)
                onEvent(parsed)
            }
            pendingEvents.add(t)
        }

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
                redactions: AgentSensitiveRedactions.values(for: task),
                durationMs: run.completedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) }
            )
        }

        // Compact events if they've grown too large
        Self.compactEvents(for: task, modelContext: modelContext)

        let finishedAt = Date()
        task.updatedAt = finishedAt
        if task.isTerminal {
            task.completedAt = finishedAt
        }
        task.markUnreadForCurrentStatus(at: finishedAt)

        // Auto-export workspace config so Import picks up follow-up runs
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: Self.runPersistenceFields(task: task, run: run, phase: "resume")
        )

        isRunning = false
    }

    @MainActor
    private func executeCopilot(
        task: AgentTask,
        modelContext: ModelContext,
        onEvent: @escaping (ParsedEvent) -> Void,
        promptOverride: String? = nil,
        startEventType: String = "task.started",
        startEventPayload: String? = nil,
        auditPhase: String = "run"
    ) async {
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "status": task.status.rawValue,
            "model": task.model,
            "runtime": AgentRuntimeID.copilotCLI.rawValue,
            "phase": auditPhase,
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

        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .running
        task.updatedAt = Date()
        task.markRead()

        let run = TaskRun(task: task)
        run.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        modelContext.insert(run)

        let startPayload = startEventPayload ?? "Copilot started working on: \(task.goal)"
        let startEvent = TaskEvent(task: task, type: startEventType, payload: startPayload, run: run)
        modelContext.insert(startEvent)

        let copilotPath = runtimeConfiguration.resolvedCopilotPath()
        guard FileManager.default.isExecutableFile(atPath: copilotPath) else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "copilot_cli_not_found"
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            run.stopReason = "missing_copilot"
            task.status = .failed
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, type: "error",
                payload: "GitHub Copilot CLI not found. Install with `brew install copilot-cli` or `npm install -g @github/copilot`, then authenticate with `copilot`.", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        let codeDir = task.codeWorkingDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codeDir, isDirectory: &isDir), isDir.boolValue else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "workspace_not_found",
                "runtime": AgentRuntimeID.copilotCLI.rawValue
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            run.stopReason = "workspace_not_found"
            task.status = .failed
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, type: "error",
                payload: "Workspace directory not found: \(codeDir)", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        let executionPath: String
        do {
            executionPath = try await IsolationService.prepare(task: task)
            if executionPath != task.effectiveWorkspacePath {
                let isoEvent = TaskEvent(task: task, type: "tool.use",
                    payload: "Isolation: \(task.isolationStrategy.rawValue) -> \(executionPath)", run: run)
                modelContext.insert(isoEvent)
            }
        } catch {
            AppLogger.audit(.isolationFailed, category: "Isolation", taskID: task.id, fields: [
                "error_type": String(describing: type(of: error)),
                "runtime": AgentRuntimeID.copilotCLI.rawValue
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            run.stopReason = "isolation_failed"
            task.status = .failed
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, type: "error",
                payload: "Workspace isolation failed: \(error.localizedDescription)", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        let prompt = promptOverride ?? buildPrompt(for: task)
        Self.logCapabilityResolution(for: task, runtime: .copilotCLI, phase: auditPhase)
        let startTime = Date()
        let beforeGitStatus = AgentFileChangeDetector.gitStatusSnapshot(workspacePath: executionPath)
        let beforeDirtyFingerprints = AgentFileChangeDetector.fileFingerprints(
            for: AgentFileChangeDetector.absolutePaths(fromGitStatus: beforeGitStatus, workspacePath: executionPath)
        )
        if !task.skills.isEmpty {
            let skillNames = task.skills.map(\.name).joined(separator: ", ")
            let skillEvent = TaskEvent(task: task, type: "skill.active",
                payload: "Active skills: \(skillNames)", run: run)
            modelContext.insert(skillEvent)
        }

        let pendingEvents = PendingTaskCollector()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: AgentRuntimeID.copilotCLI.supportsAstraRunProtocol
        )
        let streamTelemetry = AgentRuntimeStreamTelemetry()
        let result = await processRunner.runCopilotProcess(
            prompt: prompt,
            task: task,
            workspacePath: executionPath,
            copilotPath: copilotPath,
            copilotHome: copilotHome,
            permissionPolicy: permissionPolicy,
            timeoutSeconds: timeoutSeconds,
            onLine: { line, parsesJSONLines in
                streamTelemetry.recordRawLine(parsesJSONLines: parsesJSONLines)
                let events: [AgentEvent] = parsesJSONLines
                    ? CopilotStreamEventParser.parseAgentEvents(line: line)
                    : [.text(text: line + "\n")]
                streamTelemetry.recordParsed(events)
                for event in events {
                    let filteredEvents = eventPipeline.process(event)
                    streamTelemetry.recordEmitted(filteredEvents)
                    for filtered in filteredEvents {
                        let t = Task { @MainActor [weak self] in
                            guard self != nil else { return }
                            AgentEventRecorder.recordCopilotEvent(filtered, to: task, run: run, modelContext: modelContext)
                            if let parsed = AgentEventRecorder.parsedEvent(from: filtered) {
                                onEvent(parsed)
                            }
                        }
                        pendingEvents.add(t)
                    }
                }
            }
        )
        let flushedEvents = eventPipeline.flushAgentEvents()
        streamTelemetry.recordEmitted(flushedEvents)
        for event in flushedEvents {
            let t = Task { @MainActor [weak self] in
                guard self != nil else { return }
                AgentEventRecorder.recordCopilotEvent(event, to: task, run: run, modelContext: modelContext)
                if let parsed = AgentEventRecorder.parsedEvent(from: event) {
                    onEvent(parsed)
                }
            }
            pendingEvents.add(t)
        }
        await pendingEvents.drainAll()
        let streamSnapshot = streamTelemetry.snapshot()

        AgentFileChangeDetector.appendInferredFileChanges(
            to: run,
            task: task,
            modelContext: modelContext,
            workspacePath: executionPath,
            beforeGitStatus: beforeGitStatus,
            beforeDirtyFingerprints: beforeDirtyFingerprints,
            runStart: startTime
        )

        run.completedAt = Date()
        run.exitCode = result.exitCode
        run.providerVersion = result.providerVersion
        Self.logCopilotStreamTelemetry(
            snapshot: streamSnapshot,
            task: task,
            run: run,
            phase: auditPhase,
            exitCode: result.exitCode
        )
        let failureDiagnostic = result.exitCode == 0 ? nil : AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: task.model,
            exitCode: result.exitCode,
            rawError: result.error,
            providerVersion: result.providerVersion,
            stream: streamSnapshot,
            timedOut: result.timedOut,
            budgetExceeded: result.budgetExceeded || result.repetitionKilled,
            maxTurnsExceeded: result.maxTurnsExceeded
        )
        if let failureDiagnostic {
            AppLogger.audit(
                .runtimeFailureDiagnostic,
                category: "Worker",
                taskID: task.id,
                fields: failureDiagnostic.auditFields(phase: auditPhase, stream: streamSnapshot),
                level: .error
            )
        }
        AppLogger.audit(.workerExited, category: "Worker", taskID: task.id, fields: [
            "exit_code": String(result.exitCode),
            "runtime": AgentRuntimeID.copilotCLI.rawValue,
            "phase": auditPhase
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
        } else if result.maxTurnsExceeded {
            run.status = .budgetExceeded
            run.stopReason = "max_turns_reached"
            task.status = .budgetExceeded
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "Max turns reached (\(task.maxTurns)). Process killed.", run: run)
            modelContext.insert(event)
        } else if result.budgetExceeded {
            run.status = .budgetExceeded
            run.stopReason = result.repetitionKilled ? "repetition_detected" : "max_budget_reached"
            task.status = .budgetExceeded
            let reason = result.repetitionKilled ? "Repetition loop detected" : "Token budget exceeded"
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). Process killed.", run: run)
            modelContext.insert(event)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            switch task.validationStrategy {
            case .manual:
                task.status = .completed
                let event = TaskEvent(task: task, type: "task.completed", payload: "Copilot finished.", run: run)
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
            let payload = failureDiagnostic?.userFacingPayload(
                prefix: "Copilot exited with code \(result.exitCode)."
            ) ?? enrichedFailurePayload(
                prefix: "Copilot exited with code \(result.exitCode).",
                rawError: result.error
            )
            let event = TaskEvent(task: task, type: "error", payload: payload, run: run)
            modelContext.insert(event)
        }

        let folder = (try? task.ensureTaskFolder()) ?? ""
        if !folder.isEmpty {
            SessionHistoryManager.recordTurn(
                taskFolder: folder,
                taskTitle: task.title,
                turnMessage: promptOverride == nil ? task.goal : (startEventPayload ?? task.goal),
                output: run.output,
                tokensUsed: run.tokensUsed,
                costUSD: run.costUSD,
                fileChanges: run.fileChanges,
                redactions: AgentSensitiveRedactions.values(for: task),
                durationMs: run.completedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) }
            )
        }

        IsolationService.cleanup(task: task, executionPath: executionPath)
        Self.compactEvents(for: task, modelContext: modelContext)
        let finishedAt = Date()
        task.updatedAt = finishedAt
        if task.isTerminal {
            task.completedAt = finishedAt
        }
        task.markUnreadForCurrentStatus(at: finishedAt)
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: Self.runPersistenceFields(task: task, run: run, phase: auditPhase)
        )
        isRunning = false
    }

    @MainActor
    func cancel() {
        cancellationRequested = true
        processRunner.cancel()
    }

    // MARK: - Private

    typealias ProcessResult = AgentProcessResult
    typealias ProcessMonitor = AgentProcessMonitor

    static let compactionThreshold = AgentEventCompactor.threshold
    static let compactionKeepCount = AgentEventCompactor.keepCount

    @MainActor
    private static func logCopilotStreamTelemetry(
        snapshot: AgentRuntimeStreamTelemetrySnapshot,
        task: AgentTask,
        run: TaskRun,
        phase: String,
        exitCode: Int
    ) {
        var fields = snapshot.fields
        fields["runtime"] = AgentRuntimeID.copilotCLI.rawValue
        fields["phase"] = phase
        fields["exit_code"] = String(exitCode)
        fields["run_output_chars"] = String(run.output.count)
        fields["file_changes"] = String(run.fileChanges.count)

        let completedWithoutOutput = exitCode == 0
            && run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parsedNoVisibleAnswer = snapshot.rawLineCount > 0
            && snapshot.textEventCount == 0
            && snapshot.completedEventCount == 0
        let streamLevel: LogLevel = (completedWithoutOutput || parsedNoVisibleAnswer || snapshot.unknownEventCount > 0)
            ? .warning
            : .info

        AppLogger.audit(.runtimeStreamSummary, category: "Worker", taskID: task.id, fields: fields, level: streamLevel)

        for sample in snapshot.unknownSamples {
            var fields = [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "phase": phase,
                "event_type": sample.type,
                "sample": sample.sample
            ]
            fields.merge(unknownEventShapeFields(raw: sample.sample)) { current, _ in current }
            AppLogger.audit(.runtimeUnknownEvent, category: "Worker", taskID: task.id, fields: fields, level: .warning)
        }

        if completedWithoutOutput {
            AppLogger.audit(.runtimeEmptyOutput, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "phase": phase,
                "exit_code": String(exitCode),
                "raw_lines": String(snapshot.rawLineCount),
                "parsed_events": String(snapshot.parsedEventCount),
                "text_events": String(snapshot.textEventCount),
                "completed_events": String(snapshot.completedEventCount),
                "unknown_events": String(snapshot.unknownEventCount)
            ], level: .warning)
        }
    }

    @MainActor
    private static func logCapabilityResolution(for task: AgentTask, runtime: AgentRuntimeID, phase: String) {
        let resolver = TaskCapabilityResolver(task: task)
        let connectors = resolver.allConnectors
        let tools = resolver.allLocalTools
        AppLogger.audit(.capabilityResolved, category: "Worker", taskID: task.id, fields: [
            "runtime": runtime.rawValue,
            "phase": phase,
            "workspace_id": task.workspace?.id.uuidString ?? "none",
            "workspace_enabled_capabilities_count": String(task.workspace?.enabledCapabilityIDs.count ?? 0),
            "workspace_enabled_global_skills_count": String(task.workspace?.enabledGlobalSkillIDs.count ?? 0),
            "workspace_enabled_global_connectors_count": String(task.workspace?.enabledGlobalConnectorIDs.count ?? 0),
            "workspace_enabled_global_tools_count": String(task.workspace?.enabledGlobalToolIDs.count ?? 0),
            "task_skill_count": String(task.skills.count),
            "task_skill_snapshot_count": String(task.skillSnapshots.count),
            "connector_count": String(connectors.count),
            "local_tool_count": String(tools.count),
            "skill_names": compactNames(task.skills.map(\.name)),
            "connector_names": compactNames(connectors.map(\.name)),
            "local_tool_names": compactNames(tools.map(\.name))
        ], level: .debug)
    }

    @MainActor
    private static func runPersistenceFields(task: AgentTask, run: TaskRun, phase: String) -> [String: String] {
        let runEvents = task.events.filter { $0.run?.id == run.id }
        return [
            "phase": phase,
            "runtime": run.runtimeID ?? task.resolvedRuntimeID.rawValue,
            "task_status": task.status.rawValue,
            "run_status": run.status.rawValue,
            "run_stop_reason": run.stopReason,
            "exit_code": run.exitCode.map(String.init) ?? "none",
            "run_output_chars": String(run.output.count),
            "response_event_count": String(runEvents.filter { $0.type == "agent.response" }.count),
            "thinking_event_count": String(runEvents.filter { $0.type == "agent.thinking" }.count),
            "tool_use_event_count": String(runEvents.filter { $0.type == "tool.use" }.count),
            "tool_result_event_count": String(runEvents.filter { $0.type == "tool.result" }.count),
            "error_event_count": String(runEvents.filter { $0.type == "error" }.count),
            "run_event_count": String(runEvents.count),
            "file_changes": String(run.fileChanges.count),
            "tokens_input": String(run.inputTokens),
            "tokens_output": String(run.outputTokens),
            "provider_version": run.providerVersion ?? "unknown"
        ]
    }

    private static func compactNames(_ names: [String], limit: Int = 8) -> String {
        let visible = names.prefix(limit).joined(separator: ",")
        let remaining = names.count - min(names.count, limit)
        guard remaining > 0 else { return visible }
        return visible.isEmpty ? "+\(remaining)_more" : "\(visible),+\(remaining)_more"
    }

    private static func unknownEventShapeFields(raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["raw_length": String(raw.count)]
        }

        var fields: [String: String] = [
            "raw_length": String(raw.count),
            "top_level_keys": object.keys.sorted().joined(separator: ",")
        ]
        if let dataObject = object["data"] as? [String: Any] {
            fields["data_keys"] = dataObject.keys.sorted().joined(separator: ",")
        }
        if let payloadObject = object["payload"] as? [String: Any] {
            fields["payload_keys"] = payloadObject.keys.sorted().joined(separator: ",")
        }
        if let type = object["type"] as? String {
            fields["type_field"] = type
        }
        return fields
    }

    @MainActor
    static func compactEvents(for task: AgentTask, modelContext: ModelContext) {
        AgentEventCompactor.compactEvents(for: task, modelContext: modelContext)
    }

    static func ensureSubAgentPermissions(at workspacePath: String, policy: PermissionPolicy, allowedTools: [String]) {
        if ClaudeSettingsStore.ensureSubAgentPermissions(
            at: workspacePath,
            policy: policy,
            allowedTools: allowedTools
        ) {
            AppLogger.audit(.workerStarted, category: "Worker", fields: [
                "event": "subagent_permissions_ensured",
                "policy": policy.rawValue
            ])
        }
    }

    func buildPrompt(for task: AgentTask) -> String {
        AgentPromptBuilder.buildPrompt(for: task)
    }

    /// Model used for AI validation checks
    var validationModel: String = "claude-haiku-4-5-20251001"

    /// Maximum execution time in seconds (10 minutes default)
    var timeoutSeconds: TimeInterval = 600

    /// Permission policy applied to CLI runs. Review/restricted is the safe default;
    /// the composer security gate can opt into autonomous runs for trusted work.
    var skipPermissions: Bool = false
    var permissionPolicy: PermissionPolicy = .restricted

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
