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

/// Serializes main-actor event recording while still allowing runtime readers to
/// enqueue work immediately from background pipe callbacks.
final class OrderedMainActorTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var tail: Task<Void, Never>?

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return tasks.count
    }

    func add(_ operation: @escaping @MainActor () -> Void) {
        lock.lock()
        let previous = tail
        let task = Task { @MainActor in
            if let previous {
                await previous.value
            }
            operation()
        }
        tasks.append(task)
        tail = task
        lock.unlock()
    }

    private func takeTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    func drainAll() async {
        await takeTail()?.value
    }
}

@Observable
final class AgentRuntimeWorker {
    private(set) var isRunning = false
    private var cancellationRequested = false
    private var runtimeConfiguration = AgentRuntimeConfiguration()
    private let processRunner = AgentRuntimeProcessRunner()
    var budgetEnforcementModeOverride: BudgetEnforcementMode?

    private var currentBudgetEnforcementMode: BudgetEnforcementMode {
        budgetEnforcementModeOverride ?? .configuredDefault
    }

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
            "default_runtime": defaultRuntimeID.rawValue,
            "provider_path_configured": String(!runtimeConfiguration.executablePath(for: defaultRuntimeID).isEmpty)
        ], level: .debug)
    }

    /// Execute a task with its configured agent runtime.
    @MainActor
    func execute(
        task: AgentTask,
        modelContext: ModelContext,
        promptOverride: String? = nil,
        startEventPayload: String? = nil,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        let selectedRuntime = runtimeConfiguration.selectedRuntime(for: task)
        alignTaskModelWithSelectedRuntime(task, selectedRuntime: selectedRuntime, phase: "run")
        clearMismatchedProviderSessionIfNeeded(for: task, selectedRuntime: selectedRuntime, phase: "run")
        switch selectedRuntime {
        case .copilotCLI:
            await executeCopilot(
                task: task,
                modelContext: modelContext,
                onEvent: onEvent,
                promptOverride: promptOverride,
                startEventPayload: startEventPayload,
                executionPolicy: executionPolicy
            )
            return
        case .claudeCode:
            break
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
        guard prepareTaskFolderForLaunch(task, modelContext: modelContext, phase: "run") else {
            return
        }
        isRunning = true
        cancellationRequested = false

        task.status = .running
        task.updatedAt = Date()
        task.markRead()

        let run = TaskRun(task: task)
        modelContext.insert(run)

        let startEvent = TaskEvent(
            task: task,
            type: "task.started",
            payload: startEventPayload ?? "Agent started working on: \(task.goal)",
            run: run
        )
        modelContext.insert(startEvent)

        guard await preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "run",
            contextText: task.goal
        ) else {
            return
        }

        // Verify CLI exists
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "provider_cli_not_found",
                "runtime": selectedRuntime.rawValue
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            task.status = .failed
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, type: "error",
                payload: "\(selectedRuntime.displayName) CLI not found at '\(claudePath)'. Check Settings.", run: run)
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

        let prompt = promptOverride ?? buildPrompt(for: task)
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard enforcePromptBudgetIfNeeded(
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "run",
            runtime: .claudeCode,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            return
        }
        Self.logCapabilityResolution(for: task, runtime: .claudeCode, phase: "run")
        await logGitHubCLIPreflightIfNeeded(for: task, phase: "run")
        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
            "model": task.model,
            "token_budget": String(task.tokenBudget),
            "budget_enforcement": budgetEnforcementMode.rawValue,
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
        let pendingEvents = OrderedMainActorTaskQueue()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
        )
        let recordingState = AgentEventRecordingState()
        let streamDebugCapture = AgentRuntimeStreamDebugCapture.makeIfEnabled()

        let result = await processRunner.runClaudeProcess(
            prompt: prompt,
            task: task,
            workspacePath: executionPath,
            claudePath: claudePath,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            onLine: { line in
                PerformanceSignposts.processStreamLine {
                    streamDebugCapture?.recordLine(line, parsesJSONLines: true)
                    // Parse each JSON line into structured events
                    let parsedEvents = PerformanceSignposts.parseProviderStream {
                        StreamEventParser.parseAll(line: line)
                    }
                    streamDebugCapture?.recordParsed(parsedEvents, rawLine: line)
                    for parsed in parsedEvents {
                        let filteredEvents = eventPipeline.process(parsed)
                        streamDebugCapture?.recordEmitted(filteredEvents)
                        for filtered in filteredEvents {
                            pendingEvents.add { [weak self] in
                                guard self != nil else { return }

                                PerformanceSignposts.persistProviderEvent {
                                    AgentEventRecorder.recordClaudeRunEvent(
                                        filtered,
                                        to: task,
                                        run: run,
                                        modelContext: modelContext,
                                        recordingState: recordingState
                                    )
                                }
                                onEvent(filtered)
                            }
                        }
                    }
                }
            }
        )

        let flushedEvents = eventPipeline.flushParsedEvents()
        streamDebugCapture?.recordEmitted(flushedEvents)
        for parsed in flushedEvents {
            pendingEvents.add { [weak self] in
                guard self != nil else { return }

                PerformanceSignposts.persistProviderEvent {
                    AgentEventRecorder.recordClaudeRunEvent(
                        parsed,
                        to: task,
                        run: run,
                        modelContext: modelContext,
                        recordingState: recordingState
                    )
                }
                onEvent(parsed)
            }
        }

        // Drain all pending event-processing tasks before setting final status.
        // This ensures tokensUsed, costUSD, and all SwiftData inserts are complete.
        await pendingEvents.drainAll()

        // Final status
        run.completedAt = Date()
        run.exitCode = result.exitCode
        streamDebugCapture?.recordStderr(result.error)
        if let streamDebugCapture {
            Self.logStreamDebug(
                snapshot: streamDebugCapture.snapshot(),
                runtime: .claudeCode,
                task: task,
                run: run,
                phase: "run",
                exitCode: result.exitCode
            )
        }

        AppLogger.audit(.workerExited, category: "Worker", taskID: task.id, fields: [
            "exit_code": String(result.exitCode),
            "tokens_used": String(task.tokensUsed),
            "token_budget": String(task.tokenBudget)
        ], level: result.exitCode == 0 ? .info : .warning)

        let failureDiagnostic = result.exitCode == 0 ? nil : AgentRuntimeFailureDiagnostic.classify(
            runtime: .claudeCode,
            model: task.model,
            exitCode: result.exitCode,
            rawError: result.error,
            providerVersion: run.providerVersion,
            stream: nil,
            timedOut: result.timedOut,
            budgetExceeded: result.budgetExceeded,
            maxTurnsExceeded: result.maxTurnsExceeded
        )

        if let failureDiagnostic {
            AppLogger.audit(
                .runtimeFailureDiagnostic,
                category: "Worker",
                taskID: task.id,
                fields: failureDiagnostic.auditFields(phase: "run", stream: nil),
                level: .error
            )
        }

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
        } else if Self.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.stopReason = result.repetitionKilled ? "repetition_detected" : "max_budget_reached"
            task.status = .budgetExceeded
            let reason = result.repetitionKilled ? "Repetition loop detected" : "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "reason": result.repetitionKilled ? "repetition_detected" : "max_budget_reached",
                "tokens_used": String(task.tokensUsed),
                "token_budget": String(task.tokenBudget)
            ], level: .error)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            Self.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: "run",
                budgetEnforcementMode: budgetEnforcementMode
            )

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

                let aiResult = await ValidationService.aiCheck(
                    task: task,
                    claudePath: claudePath,
                    model: validationModel,
                    utilityRuntime: utilityRuntimeConfiguration(
                        for: selectedRuntime,
                        preferredModel: validationModel
                    )
                )
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
        } else if Self.shouldPauseForRuntimePermissionApproval(
            failureDiagnostic: failureDiagnostic,
            task: task,
            run: run
        ) {
            run.status = .failed
            run.stopReason = "permission_approval_required"
            task.status = .pendingUser
            let payload = permissionApprovalRequestPayload(
                diagnostic: failureDiagnostic,
                result: result
            )
            let event = TaskEvent(task: task, type: "permission.approval.requested", payload: payload, run: run)
            modelContext.insert(event)
        } else {
            run.status = .failed
            run.stopReason = "failed"
            task.status = .failed
            let payload = failureDiagnostic?.userFacingPayload(
                prefix: "Agent exited with code \(result.exitCode)."
            ) ?? enrichedFailurePayload(
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
            let titleRuntime = utilityRuntimeConfiguration(
                for: selectedRuntime,
                preferredModel: validationModel
            )
            let taskRef = task
            Task.detached {
                if let generated = await SpecEngine.generateTitle(
                    goal: goalText,
                    workspacePath: wsPath,
                    utilityRuntime: titleRuntime
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

    @MainActor
    func executeApprovedPlan(
        task: AgentTask,
        plan: TaskPlanPayload,
        mode: TaskPlanExecutionMode = .fullPlan,
        modelContext: ModelContext,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        let currentPlan = TaskPlanService.reconstruct(for: task).plan ?? plan
        let approvedStep = mode == .nextStep ? TaskPlanService.nextExecutableStep(in: currentPlan) : nil
        if mode == .nextStep, approvedStep == nil {
            TaskPlanService.recordExecutionCompleted(planID: currentPlan.planID, task: task, modelContext: modelContext)
            task.status = .completed
            task.updatedAt = Date()
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            return
        }

        TaskPlanService.recordExecutionStarted(planID: currentPlan.planID, task: task, modelContext: modelContext)
        let prompt = if let approvedStep {
            AgentPromptBuilder.buildApprovedPlanStepExecutionPrompt(for: task, plan: currentPlan, step: approvedStep)
        } else {
            AgentPromptBuilder.buildApprovedPlanExecutionPrompt(for: task, plan: currentPlan)
        }
        let selectedRuntime = runtimeConfiguration.selectedRuntime(for: task)
        let executionPolicy = Self.approvedPlanExecutionPolicy(
            runtime: selectedRuntime,
            currentPermissionPolicy: permissionPolicy,
            task: task,
            plan: currentPlan,
            step: approvedStep
        )
        await execute(
            task: task,
            modelContext: modelContext,
            promptOverride: prompt,
            startEventPayload: approvedStep.map { "Agent started approved plan step: \($0.title)" }
                ?? "Agent started executing approved plan: \(currentPlan.title)",
            executionPolicy: executionPolicy,
            onEvent: onEvent
        )
        if task.status == .completed {
            if let approvedStep {
                finalizeApprovedPlanStep(
                    approvedStep,
                    plan: currentPlan,
                    task: task,
                    modelContext: modelContext
                )
            } else {
                finalizeApprovedFullPlan(
                    currentPlan,
                    task: task,
                    modelContext: modelContext
                )
            }
        } else if task.isTerminal {
            TaskPlanService.recordExecutionFailed(
                planID: currentPlan.planID,
                task: task,
                modelContext: modelContext,
                reason: task.status.rawValue
            )
        }
    }

    @MainActor
    private func finalizeApprovedPlanStep(
        _ step: TaskPlanPayloadStep,
        plan: TaskPlanPayload,
        task: AgentTask,
        modelContext: ModelContext
    ) {
        let stateAfterRun = TaskPlanService.reconstruct(for: task)
        let currentStepStatus = stateAfterRun.plan?.steps.first(where: { $0.id == step.id })?.status
        let shouldFallbackComplete: Bool = {
            switch currentStepStatus {
            case .done, .skipped, .blocked:
                return false
            case .pending, .running, nil:
                return true
            }
        }()
        if shouldFallbackComplete {
            TaskPlanService.recordStepProgress(
                type: TaskPlanEventTypes.stepCompleted,
                planID: plan.planID,
                stepID: step.id,
                status: .done,
                task: task,
                modelContext: modelContext,
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last,
                title: step.title,
                summary: "Completed approved step: \(step.title)"
            )
        }

        let refreshedPlan = TaskPlanService.reconstruct(for: task).plan ?? plan
        if let blockedStep = refreshedPlan.steps.first(where: { $0.id == step.id && $0.status == .blocked }) {
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: blockedStep.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Plan step blocked. Fix the blocker, then approve this step again to retry."
                    : "Plan step blocked: \(blockedStep.detail)",
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last
            )
            return
        }

        if TaskPlanService.hasRemainingExecutableSteps(in: refreshedPlan) {
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: "Plan step complete. Review the next step, then approve it when you're ready.",
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last
            )
        } else {
            TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
        }
    }

    @MainActor
    private func finalizeApprovedFullPlan(
        _ plan: TaskPlanPayload,
        task: AgentTask,
        modelContext: ModelContext
    ) {
        let refreshedPlan = TaskPlanService.reconstruct(for: task).plan ?? plan
        if let blockedStep = refreshedPlan.steps.first(where: { $0.status == .blocked }) {
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: blockedStep.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Plan blocked. Fix the blocker, then approve the plan again to retry."
                    : "Plan blocked at \(blockedStep.title): \(blockedStep.detail)",
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last
            )
            return
        }

        TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
    }

    @MainActor
    private func pauseApprovedPlanForUser(
        task: AgentTask,
        modelContext: ModelContext,
        message: String,
        run: TaskRun?
    ) {
        let notice = TaskEvent(
            task: task,
            type: "system.info",
            payload: message,
            run: run
        )
        modelContext.insert(notice)
        task.status = .pendingUser
        task.completedAt = nil
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    /// Continue an existing session with a follow-up message (HITL flow).
    @MainActor
    func continueSession(
        task: AgentTask,
        message: String,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        let selectedRuntime = runtimeConfiguration.selectedRuntime(for: task)
        alignTaskModelWithSelectedRuntime(task, selectedRuntime: selectedRuntime, phase: "resume")
        clearMismatchedProviderSessionIfNeeded(for: task, selectedRuntime: selectedRuntime, phase: "resume")
        switch selectedRuntime {
        case .copilotCLI:
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
                auditPhase: "resume",
                executionPolicy: executionPolicy
            )
            return
        case .claudeCode:
            break
        }

        guard !isRunning else {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "reason": "worker_already_running"
            ], level: .warning)
            return
        }
        guard prepareTaskFolderForLaunch(task, modelContext: modelContext, phase: "resume") else {
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

        guard await preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "resume",
            contextText: message
        ) else {
            return
        }

        // Build a fresh prompt with session history instead of --resume (which resends full conversation).
        // This cuts input tokens by ~90% on follow-ups.
        let followUpPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: message, task: task)
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard enforcePromptBudgetIfNeeded(
            prompt: followUpPrompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "resume",
            runtime: .claudeCode,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            return
        }
        Self.logCapabilityResolution(for: task, runtime: .claudeCode, phase: "resume")
        await logGitHubCLIPreflightIfNeeded(for: task, phase: "resume")

        AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
            "mode": task.sessionId == nil ? "fresh_follow_up" : "session_follow_up",
            "runtime": AgentRuntimeID.claudeCode.rawValue,
            "budget_enforcement": budgetEnforcementMode.rawValue,
            "message_length": String(message.count),
            "prompt_chars": String(followUpPrompt.count),
            "history_run_count": String(task.runs.count),
            "history_output_chars": String(task.runs.reduce(0) { $0 + $1.output.count }),
            "has_session_id": String(task.sessionId != nil),
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])

        let pendingEvents = OrderedMainActorTaskQueue()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
        )
        let recordingState = AgentEventRecordingState()
        let streamDebugCapture = AgentRuntimeStreamDebugCapture.makeIfEnabled()

        let result = await processRunner.runClaudeProcess(
            prompt: followUpPrompt,
            task: task,
            workspacePath: task.codeWorkingDirectory,
            claudePath: claudePath,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            onLine: { line in
                PerformanceSignposts.processStreamLine {
                    streamDebugCapture?.recordLine(line, parsesJSONLines: true)
                    let parsedEvents = PerformanceSignposts.parseProviderStream {
                        StreamEventParser.parseAll(line: line)
                    }
                    streamDebugCapture?.recordParsed(parsedEvents, rawLine: line)
                    for parsed in parsedEvents {
                        let filteredEvents = eventPipeline.process(parsed)
                        streamDebugCapture?.recordEmitted(filteredEvents)
                        for filtered in filteredEvents {
                            pendingEvents.add {
                                PerformanceSignposts.persistProviderEvent {
                                    AgentEventRecorder.recordClaudeFollowUpEvent(
                                        filtered,
                                        to: task,
                                        run: run,
                                        modelContext: modelContext,
                                        recordingState: recordingState
                                    )
                                }
                                onEvent(filtered)
                            }
                        }
                    }
                }
            }
        )

        let flushedEvents = eventPipeline.flushParsedEvents()
        streamDebugCapture?.recordEmitted(flushedEvents)
        for parsed in flushedEvents {
            pendingEvents.add {
                PerformanceSignposts.persistProviderEvent {
                    AgentEventRecorder.recordClaudeFollowUpEvent(
                        parsed,
                        to: task,
                        run: run,
                        modelContext: modelContext,
                        recordingState: recordingState
                    )
                }
                onEvent(parsed)
            }
        }

        // Drain all pending event-processing tasks before setting final status
        await pendingEvents.drainAll()

        run.completedAt = Date()
        run.exitCode = result.exitCode
        streamDebugCapture?.recordStderr(result.error)
        if let streamDebugCapture {
            Self.logStreamDebug(
                snapshot: streamDebugCapture.snapshot(),
                runtime: .claudeCode,
                task: task,
                run: run,
                phase: "resume",
                exitCode: result.exitCode
            )
        }

        let failureDiagnostic = result.exitCode == 0 ? nil : AgentRuntimeFailureDiagnostic.classify(
            runtime: .claudeCode,
            model: task.model,
            exitCode: result.exitCode,
            rawError: result.error,
            providerVersion: run.providerVersion,
            stream: nil,
            timedOut: result.timedOut,
            budgetExceeded: result.budgetExceeded,
            maxTurnsExceeded: result.maxTurnsExceeded
        )

        if let failureDiagnostic {
            AppLogger.audit(
                .runtimeFailureDiagnostic,
                category: "Worker",
                taskID: task.id,
                fields: failureDiagnostic.auditFields(phase: "resume", stream: nil),
                level: .error
            )
        }

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
        } else if Self.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.stopReason = result.repetitionKilled ? "repetition_detected" : "max_budget_reached"
            task.status = .budgetExceeded
            let reason = result.repetitionKilled ? "Repetition loop detected" : "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
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
            Self.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: "resume",
                budgetEnforcementMode: budgetEnforcementMode
            )
            let event = TaskEvent(task: task, type: "task.completed", payload: "Follow-up completed.", run: run)
            modelContext.insert(event)
        } else if Self.shouldPauseForRuntimePermissionApproval(
            failureDiagnostic: failureDiagnostic,
            task: task,
            run: run
        ) {
            run.status = .failed
            run.stopReason = "permission_approval_required"
            task.status = .pendingUser
            let payload = permissionApprovalRequestPayload(
                diagnostic: failureDiagnostic,
                result: result
            )
            let event = TaskEvent(task: task, type: "permission.approval.requested", payload: payload, run: run)
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
                let payload = failureDiagnostic?.userFacingPayload(
                    prefix: "Follow-up failed (exit \(result.exitCode))."
                ) ?? enrichedFailurePayload(
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
        auditPhase: String = "run",
        executionPolicy: AgentRuntimeExecutionPolicy = .default
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
        guard prepareTaskFolderForLaunch(task, modelContext: modelContext, phase: auditPhase) else {
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

        guard await preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            contextText: promptOverride ?? startPayload
        ) else {
            return
        }

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
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard enforcePromptBudgetIfNeeded(
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            runtime: .copilotCLI,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            return
        }
        Self.logCapabilityResolution(for: task, runtime: .copilotCLI, phase: auditPhase)
        await logGitHubCLIPreflightIfNeeded(for: task, phase: auditPhase)
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

        let pendingEvents = OrderedMainActorTaskQueue()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: AgentRuntimeID.copilotCLI.supportsAstraRunProtocol
        )
        let recordingState = AgentEventRecordingState()
        let streamTelemetry = AgentRuntimeStreamTelemetry()
        let streamDebugCapture = AgentRuntimeStreamDebugCapture.makeIfEnabled()
        let result = await processRunner.runCopilotProcess(
            prompt: prompt,
            task: task,
            workspacePath: executionPath,
            copilotPath: copilotPath,
            copilotHome: copilotHome,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            onLine: { line, parsesJSONLines in
                PerformanceSignposts.processStreamLine {
                    streamTelemetry.recordRawLine(parsesJSONLines: parsesJSONLines)
                    streamDebugCapture?.recordLine(line, parsesJSONLines: parsesJSONLines)
                    let events: [AgentEvent] = PerformanceSignposts.parseProviderStream {
                        parsesJSONLines
                            ? CopilotStreamEventParser.parseAgentEvents(line: line)
                            : CopilotStreamEventParser.parsePlainTextAgentEvents(line: line, appendingNewline: true)
                    }
                    streamTelemetry.recordParsed(events)
                    streamDebugCapture?.recordParsed(events, rawLine: line)
                    for event in events {
                        let filteredEvents = eventPipeline.process(event)
                        streamTelemetry.recordEmitted(filteredEvents)
                        streamDebugCapture?.recordEmitted(filteredEvents)
                        for filtered in filteredEvents {
                            pendingEvents.add { [weak self] in
                                guard self != nil else { return }
                                PerformanceSignposts.persistProviderEvent {
                                    AgentEventRecorder.recordCopilotEvent(
                                        filtered,
                                        to: task,
                                        run: run,
                                        modelContext: modelContext,
                                        recordingState: recordingState
                                    )
                                }
                                if let parsed = AgentEventRecorder.parsedEvent(from: filtered) {
                                    onEvent(parsed)
                                }
                            }
                        }
                    }
                }
            }
        )
        let flushedEvents = eventPipeline.flushAgentEvents()
        streamTelemetry.recordEmitted(flushedEvents)
        streamDebugCapture?.recordEmitted(flushedEvents)
        for event in flushedEvents {
            pendingEvents.add { [weak self] in
                guard self != nil else { return }
                PerformanceSignposts.persistProviderEvent {
                    AgentEventRecorder.recordCopilotEvent(
                        event,
                        to: task,
                        run: run,
                        modelContext: modelContext,
                        recordingState: recordingState
                    )
                }
                if let parsed = AgentEventRecorder.parsedEvent(from: event) {
                    onEvent(parsed)
                }
            }
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
        streamDebugCapture?.recordStderr(result.error)
        Self.logCopilotStreamTelemetry(
            snapshot: streamSnapshot,
            task: task,
            run: run,
            phase: auditPhase,
            exitCode: result.exitCode
        )
        if let streamDebugCapture {
            Self.logStreamDebug(
                snapshot: streamDebugCapture.snapshot(),
                runtime: .copilotCLI,
                task: task,
                run: run,
                phase: auditPhase,
                exitCode: result.exitCode
            )
        }
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
        } else if Self.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.stopReason = result.repetitionKilled ? "repetition_detected" : "max_budget_reached"
            task.status = .budgetExceeded
            let reason = result.repetitionKilled ? "Repetition loop detected" : "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
            modelContext.insert(event)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            Self.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: auditPhase,
                budgetEnforcementMode: budgetEnforcementMode
            )
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
                let aiResult = await ValidationService.aiCheck(
                    task: task,
                    claudePath: claudePath,
                    model: validationModel,
                    utilityRuntime: utilityRuntimeConfiguration(
                        for: .copilotCLI,
                        preferredModel: validationModel
                    )
                )
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
        } else if Self.shouldPauseForRuntimePermissionApproval(
            failureDiagnostic: failureDiagnostic,
            task: task,
            run: run
        ) {
            run.status = .failed
            run.stopReason = "permission_approval_required"
            task.status = .pendingUser
            let payload = permissionApprovalRequestPayload(
                diagnostic: failureDiagnostic,
                result: result
            )
            let event = TaskEvent(task: task, type: "permission.approval.requested", payload: payload, run: run)
            modelContext.insert(event)
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

    private func utilityRuntimeConfiguration(
        for runtime: AgentRuntimeID,
        preferredModel: String
    ) -> AgentUtilityRuntimeConfiguration {
        let model = RuntimeModelAvailability.normalizedModel(preferredModel, for: runtime)
        return AgentUtilityRuntimeConfiguration(
            runtime: runtime,
            model: model,
            claudePath: claudePath,
            copilotPath: copilotPath,
            copilotHome: copilotHome
        )
    }

    private func permissionApprovalRequestPayload(
        diagnostic: AgentRuntimeFailureDiagnostic?,
        result: AgentProcessResult
    ) -> String {
        let providerDetail = result.error?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        let detail = providerDetail.map { "\n\nProvider detail:\n\($0)" } ?? ""
        let message = diagnostic?.category == .permissionDenied
            ? diagnostic?.userMessage
            : "The provider needs a runtime permission before it can continue."
        return """
        \(message ?? "The provider needs a runtime permission before it can continue.")

        Approve to continue this task with one-time expanded runtime permissions.\(detail)
        """
    }

    @MainActor
    private static func shouldPauseForRuntimePermissionApproval(
        failureDiagnostic: AgentRuntimeFailureDiagnostic?,
        task: AgentTask,
        run: TaskRun
    ) -> Bool {
        if failureDiagnostic?.category == .permissionDenied {
            return true
        }
        return task.events.contains { event in
            event.type == "permission.denied" && event.run?.id == run.id
        }
    }

    @MainActor
    private func prepareTaskFolderForLaunch(
        _ task: AgentTask,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        do {
            let folder = try task.ensureTaskFolder()
            AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
                "event": "task_folder_prepared",
                "phase": phase,
                "folder_available": String(!folder.isEmpty)
            ], level: .debug)
            return true
        } catch {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "task_folder_create_failed",
                "phase": phase,
                "error_type": String(describing: type(of: error))
            ], level: .error)
            task.status = .failed
            let now = Date()
            task.updatedAt = now
            task.completedAt = now
            task.markUnreadForCurrentStatus(at: now)
            modelContext.insert(TaskEvent(
                task: task,
                type: "error",
                payload: "ASTRA could not create this task's output folder before launching the agent: \(error.localizedDescription)"
            ))
            try? modelContext.save()
            return false
        }
    }

    typealias ProcessResult = AgentProcessResult
    typealias ProcessMonitor = AgentProcessMonitor

    static let compactionThreshold = AgentEventCompactor.threshold
    static let compactionKeepCount = AgentEventCompactor.keepCount

    @MainActor
    private func alignTaskModelWithSelectedRuntime(
        _ task: AgentTask,
        selectedRuntime: AgentRuntimeID,
        phase: String
    ) {
        let resolution = RuntimeModelAvailability.resolveModel(task.model, for: selectedRuntime)
        var fields = resolution.diagnosticFields(phase: phase)
        fields["task_runtime_id"] = task.runtimeID ?? "none"
        fields["default_runtime"] = runtimeConfiguration.defaultRuntimeID.rawValue
        AppLogger.audit(
            .runtimeModelSelection,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: resolution.changed ? .info : .debug,
            fieldMaxLength: 200
        )
        guard resolution.changed else { return }
        task.model = resolution.resolvedModel
    }

    @MainActor
    private func clearMismatchedProviderSessionIfNeeded(
        for task: AgentTask,
        selectedRuntime: AgentRuntimeID,
        phase: String
    ) {
        guard let sessionID = task.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return
        }

        let sessionRun = task.runs
            .filter { $0.providerSessionId == sessionID }
            .max { $0.startedAt < $1.startedAt }
        let latestRun = task.runs.max { $0.startedAt < $1.startedAt }
        let owningRuntime = Self.runtimeID(from: sessionRun?.runtimeID)
            ?? Self.runtimeID(from: latestRun?.runtimeID)

        guard let owningRuntime, owningRuntime != selectedRuntime else {
            return
        }

        task.sessionId = nil
        AppLogger.audit(.workerSessionCleared, category: "Worker", taskID: task.id, fields: [
            "reason": "runtime_changed",
            "from_runtime": owningRuntime.rawValue,
            "to_runtime": selectedRuntime.rawValue,
            "phase": phase,
            "history_run_count": String(task.runs.count)
        ], level: .info)
    }

    private static func runtimeID(from rawValue: String?) -> AgentRuntimeID? {
        rawValue.flatMap(AgentRuntimeID.init(rawValue:))
    }

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
            && snapshot.completedEventCount == 0
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
    private static func logStreamDebug(
        snapshot: AgentRuntimeStreamDebugSnapshot,
        runtime: AgentRuntimeID,
        task: AgentTask,
        run: TaskRun,
        phase: String,
        exitCode: Int
    ) {
        var fields = snapshot.fields
        fields["runtime"] = runtime.rawValue
        fields["phase"] = phase
        fields["exit_code"] = String(exitCode)
        fields["run_output_chars"] = String(run.output.count)
        fields["file_changes"] = String(run.fileChanges.count)

        AppLogger.audit(
            .runtimeStreamDebug,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: .debug,
            fieldMaxLength: 240
        )

        for (index, sample) in snapshot.rawSamples.enumerated() {
            AppLogger.audit(
                .runtimeStreamDebugSample,
                category: "Worker",
                taskID: task.id,
                fields: [
                    "runtime": runtime.rawValue,
                    "phase": phase,
                    "sample_kind": "raw_line",
                    "sample_index": String(index + 1),
                    "sample": sample
                ],
                level: .debug,
                fieldMaxLength: 500
            )
        }

        for (index, shape) in snapshot.unknownJSONShapes.enumerated() {
            AppLogger.audit(
                .runtimeStreamDebugSample,
                category: "Worker",
                taskID: task.id,
                fields: [
                    "runtime": runtime.rawValue,
                    "phase": phase,
                    "sample_kind": "unknown_json_shape",
                    "sample_index": String(index + 1),
                    "shape": shape
                ],
                level: .debug,
                fieldMaxLength: 500
            )
        }

        if let stderrTail = snapshot.stderrTail, !stderrTail.isEmpty {
            AppLogger.audit(
                .runtimeStreamDebugSample,
                category: "Worker",
                taskID: task.id,
                fields: [
                    "runtime": runtime.rawValue,
                    "phase": phase,
                    "sample_kind": "stderr_tail",
                    "tail": stderrTail
                ],
                level: .debug,
                fieldMaxLength: 500
            )
        }
    }

    @MainActor
    private func preflightConnectorsBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        contextText: String
    ) async -> Bool {
        let fullContext = [
            task.goal,
            task.title,
            contextText
        ].joined(separator: "\n")
        let connectors = ConnectorPreflightService.connectorsRequiringPreflight(
            from: TaskCapabilityResolver(task: task).allConnectors,
            contextText: fullContext
        )
        let traceID = AuditTrace.make("connector-preflight")
        var preflightFields = CapabilityAudit.taskContextFields(source: "connector_preflight_candidates", task: task)
        preflightFields["trace_id"] = traceID
        preflightFields["phase"] = phase
        preflightFields["preflight_connector_count"] = String(connectors.count)
        AppLogger.audit(.capabilityChatContext, category: "Worker", taskID: task.id, fields: preflightFields, level: .debug, fieldMaxLength: 240)

        guard let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: connectors,
            contextText: fullContext,
            workspaceID: task.workspace?.id,
            traceID: traceID
        ) else {
            if !connectors.isEmpty {
                AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: [
                    "source": "task_preflight",
                    "trace_id": traceID,
                    "phase": phase,
                    "workspace_id": task.workspace?.id.uuidString ?? "none",
                    "result": "preflight_passed",
                    "connector_count": String(connectors.count),
                    "connector_names": CapabilityAudit.compactNames(connectors.map(\.name))
                ], level: .info, fieldMaxLength: 240)
            }
            return true
        }

        var fields = issue.auditFields
        fields["trace_id"] = traceID
        fields["phase"] = phase
        AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: fields, level: .error)

        let message = """
        \(issue.connectorName) connector check failed before the agent ran:

        \(issue.message)

        Fix this connector in Manage Capabilities, then retry the task. ASTRA stopped here so the agent does not guess about Jira permissions from partial API results.
        """
        finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: modelContext,
            reason: "connector_preflight_failed",
            payload: message
        )
        return false
    }

    @MainActor
    private func finishPreLaunchFailure(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        reason: String,
        payload: String
    ) {
        run.status = .failed
        run.stopReason = reason
        run.completedAt = Date()
        task.status = .failed
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)
        let event = TaskEvent(task: task, type: "error", payload: payload, run: run)
        modelContext.insert(event)
        AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
            "reason": reason
        ], level: .error)
        try? modelContext.save()
        isRunning = false
    }

    @MainActor
    private static func logCapabilityResolution(for task: AgentTask, runtime: AgentRuntimeID, phase: String) {
        let resolver = TaskCapabilityResolver(task: task)
        let connectors = resolver.allConnectors
        let tools = resolver.allLocalTools
        let skills = resolver.allBehaviorSkills
        AppLogger.audit(.capabilityResolved, category: "Worker", taskID: task.id, fields: [
            "runtime": runtime.rawValue,
            "phase": phase,
            "workspace_id": task.workspace?.id.uuidString ?? "none",
            "workspace_enabled_capabilities_count": String(task.workspace?.enabledCapabilityIDs.count ?? 0),
            "workspace_enabled_capability_ids": CapabilityAudit.compactNames(task.workspace?.enabledCapabilityIDs ?? []),
            "workspace_enabled_global_skills_count": String(task.workspace?.enabledGlobalSkillIDs.count ?? 0),
            "workspace_enabled_global_connectors_count": String(task.workspace?.enabledGlobalConnectorIDs.count ?? 0),
            "workspace_enabled_global_tools_count": String(task.workspace?.enabledGlobalToolIDs.count ?? 0),
            "task_skill_count": String(task.skills.count),
            "task_skill_snapshot_count": String(task.skillSnapshots.count),
            "resolved_skill_count": String(skills.count),
            "connector_count": String(connectors.count),
            "local_tool_count": String(tools.count),
            "skill_names": compactNames(task.skills.map(\.name)),
            "resolved_skill_names": compactNames(skills.map(\.name)),
            "connector_names": compactNames(connectors.map(\.name)),
            "local_tool_names": compactNames(tools.map(\.name))
        ], level: .debug, fieldMaxLength: 240)
    }

    @MainActor
    private func logGitHubCLIPreflightIfNeeded(for task: AgentTask, phase: String) async {
        let resolver = TaskCapabilityResolver(task: task)
        let tools = resolver.allLocalTools
        let hasGitHubTool = tools.contains { tool in
            tool.command.trimmingCharacters(in: .whitespacesAndNewlines) == "gh"
        }
        let hasGitHubSkill = resolver.allBehaviorSkills.contains { skill in
            let name = skill.name.lowercased()
            return name.contains("github") || name.contains("git hub")
        }
        guard hasGitHubTool || hasGitHubSkill else { return }

        let gh = RuntimePathResolver.detectExecutablePath(named: "gh")
        var fields: [String: String] = [
            "source": "task_preflight",
            "phase": phase,
            "command": "gh",
            "matched_tool": String(hasGitHubTool),
            "matched_skill": String(hasGitHubSkill),
            "runtime": runtimeConfiguration.selectedRuntime(for: task).rawValue
        ]

        guard !gh.isEmpty, FileManager.default.isExecutableFile(atPath: gh) else {
            fields["result"] = "executable_missing"
            AppLogger.audit(.localToolTested, category: "Worker", taskID: task.id, fields: fields, level: .warning)
            return
        }

        fields["executable_path"] = gh
        let runner = ProcessBinaryRunner()
        let version = await runner.run(path: gh, args: ["--version"], timeout: 3, environment: nil)
        fields["version_result"] = Self.runResultLabel(version)
        if version.isSuccess,
           let firstLine = version.stdout.split(separator: "\n").first {
            fields["version_summary"] = String(firstLine)
        }

        let auth = await runner.run(
            path: gh,
            args: ["auth", "status", "--hostname", "github.com"],
            timeout: 5,
            environment: nil
        )
        fields["auth_result"] = Self.runResultLabel(auth)
        fields["result"] = auth.isSuccess ? "authenticated" : Self.runResultLabel(auth)
        AppLogger.audit(
            .localToolTested,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: auth.isSuccess ? .debug : .warning,
            fieldMaxLength: 220
        )
    }

    private static func runResultLabel(_ result: RunResult) -> String {
        switch result.outcome {
        case .exited(code: 0):
            return "success"
        case .exited:
            return "auth_failed"
        case .timedOut:
            return "timeout"
        case .launchFailed:
            return "launch_failed"
        }
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

    private static func approvedPlanExecutionPolicy(
        runtime: AgentRuntimeID,
        currentPermissionPolicy: PermissionPolicy,
        task: AgentTask,
        plan: TaskPlanPayload,
        step approvedStep: TaskPlanPayloadStep? = nil
    ) -> AgentRuntimeExecutionPolicy {
        AgentRuntimeExecutionPolicy.approvedPlan(
            runtime: runtime,
            currentPermissionPolicy: currentPermissionPolicy,
            allowedTools: approvedPlanAllowedTools(for: task, plan: plan, step: approvedStep)
        )
    }

    private static func approvedPlanAllowedTools(
        for task: AgentTask,
        plan: TaskPlanPayload,
        step approvedStep: TaskPlanPayloadStep? = nil
    ) -> [String] {
        var tools = Set(task.resolvedProviderAllowedTools)
        let scopedSteps = approvedStep.map { [$0] } ?? plan.steps
        for step in scopedSteps {
            for tool in step.likelyTools {
                tools.insert(tool)
            }
            if stepLooksWebBacked(step) {
                tools.insert("WebFetch")
            }
        }
        if planTextLooksWebBacked(plan.title) || planTextLooksWebBacked(plan.goal) {
            tools.insert("WebFetch")
        }
        return Array(tools).sorted()
    }

    private static func stepLooksWebBacked(_ step: TaskPlanPayloadStep) -> Bool {
        planTextLooksWebBacked(step.title) ||
            planTextLooksWebBacked(step.detail) ||
            step.likelyTools.contains { ["WebFetch", "WebSearch"].contains($0) }
    }

    private static func planTextLooksWebBacked(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["http://", "https://", "web", "fetch", "research", "curl", "api", "ncbi"]
            .contains { lower.contains($0) }
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

    @MainActor
    private func enforcePromptBudgetIfNeeded(
        prompt: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        runtime: AgentRuntimeID,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        let tokenBudget = AgentRuntimeProcessRunner.effectiveTokenBudget(for: task)
        guard tokenBudget != Int.max else { return true }

        let estimatedInputTokens = AgentRuntimeProcessRunner.estimatedLaunchInputTokens(prompt: prompt, runtime: runtime)
        guard estimatedInputTokens > tokenBudget else { return true }

        let fields = [
            "phase": phase,
            "reason": "prompt_budget_estimate_exceeded",
            "estimated_input_tokens": String(estimatedInputTokens),
            "launch_overhead_tokens": String(AgentRuntimeProcessRunner.launchOverheadTokens(for: runtime)),
            "runtime": runtime.rawValue,
            "token_budget": String(tokenBudget),
            "configured_task_budget": String(task.tokenBudget),
            "enforcement": budgetEnforcementMode.rawValue
        ]

        if budgetEnforcementMode == .warning {
            let message = "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). ASTRA started the provider because Budget Enforcement is set to Warning Only."
            modelContext.insert(TaskEvent(task: task, type: "budget.warning", payload: message, run: run))
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .warning)
            return true
        }

        run.status = .budgetExceeded
        run.completedAt = Date()
        run.stopReason = "max_budget_reached"
        task.status = .budgetExceeded
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)
        let message = "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). Provider was not started."
        modelContext.insert(TaskEvent(task: task, type: "budget.exceeded", payload: message, run: run))
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .error)
        try? modelContext.save()
        isRunning = false
        return false
    }

    @MainActor
    private static func hasReportedTokensAboveBudget(task: AgentTask) -> Bool {
        let tokenBudget = AgentRuntimeProcessRunner.effectiveTokenBudget(for: task)
        return tokenBudget != Int.max && task.tokensUsed > tokenBudget
    }

    @MainActor
    private static func shouldTreatAsBudgetExceeded(
        result: AgentProcessResult,
        task: AgentTask,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        result.budgetExceeded ||
            (budgetEnforcementMode == .hardStop && hasReportedTokensAboveBudget(task: task))
    }

    @MainActor
    private static func recordFinalBudgetWarningIfNeeded(
        result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        budgetEnforcementMode: BudgetEnforcementMode
    ) {
        let reportedBudgetWarning = budgetEnforcementMode == .warning && hasReportedTokensAboveBudget(task: task)
        guard result.budgetWarning || result.finalReportedBudgetExceededAfterCompletion || reportedBudgetWarning else {
            return
        }
        let message: String
        let reason: String
        if result.budgetWarning || reportedBudgetWarning {
            message = "Budget exceeded in warning mode (\(task.tokensUsed)/\(task.tokenBudget)). ASTRA kept the provider running because Budget Enforcement is set to Warning Only."
            reason = "budget_exceeded_warning_mode"
        } else {
            message = "Completed after exceeding the reported provider token budget (\(task.tokensUsed)/\(task.tokenBudget)). The completion marker was emitted before the final usage report, so ASTRA recorded this as a warning instead of a budget kill."
            reason = "final_reported_budget_exceeded_after_completion"
        }
        modelContext.insert(TaskEvent(
            task: task,
            type: "budget.warning",
            payload: message,
            run: run
        ))
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
            "phase": phase,
            "reason": reason,
            "tokens_used": String(task.tokensUsed),
            "token_budget": String(task.tokenBudget)
        ], level: .warning)
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
