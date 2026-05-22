import Foundation
import SwiftData
import ASTRACore

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

    var defaultAgentPolicyLevelRaw: String = AgentPolicyLevel.review.rawValue

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
        guard AgentRuntimeLaunchPreflight.prepareTaskFolderForLaunch(
            task,
            modelContext: modelContext,
            phase: "run"
        ) else {
            isRunning = false
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

        guard await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "run",
            contextText: task.goal
        ) else {
            isRunning = false
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
        let codeDir = TaskWorkspaceAccess(task: task).codeWorkingDirectory
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
            if executionPath != TaskWorkspaceAccess(task: task).effectiveWorkspacePath {
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
        logContextPromptDiagnostics(for: task, prompt: prompt, phase: "run")
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "run",
            runtime: .claudeCode,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            isRunning = false
            return
        }
        Self.logCapabilityResolution(for: task, runtime: .claudeCode, phase: "run")
        await logGitHubCLIPreflightIfNeeded(for: task, phase: "run")
        let runPermissionPolicy = effectivePermissionPolicy(for: task, executionPolicy: executionPolicy)
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: task.model,
            workspacePath: executionPath,
            phase: "run",
            permissionPolicy: runPermissionPolicy,
            executionPolicy: executionPolicy,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            modelContext: modelContext
        )
        guard shouldStartProvider(with: manifest, task: task, run: run, modelContext: modelContext, phase: "run") else {
            IsolationService.cleanup(task: task, executionPath: executionPath)
            return
        }
        let launchExecutionPolicy = executionPolicy.applyingProviderRender(manifest.providerRender)
        AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
            "model": task.model,
            "token_budget": String(task.tokenBudget),
            "budget_enforcement": budgetEnforcementMode.rawValue,
            "isolation": task.isolationStrategy.rawValue,
            "workspace_changed": String(executionPath != TaskWorkspaceAccess(task: task).effectiveWorkspacePath)
        ])

        // Log active skills
        if !task.skills.isEmpty {
            let skillNames = task.skills.map(\.name).joined(separator: ", ")
            let skillEvent = TaskEvent(task: task, type: "skill.active",
                payload: "Active skills: \(skillNames)", run: run)
            modelContext.insert(skillEvent)
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "skills_count": String(task.skills.count),
                "allowed_tools_count": String(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools.count)
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
            permissionPolicy: runPermissionPolicy,
            executionPolicy: launchExecutionPolicy,
            permissionManifest: manifest,
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
            AgentRuntimeStreamDiagnostics.logStreamDebug(
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

        let failureDiagnostic = (result.exitCode == 0 || result.runtimeStopped || result.repetitionKilled) ? nil : AgentRuntimeFailureDiagnostic.classify(
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
        } else if applyRuntimeStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: "run") {
        } else if applyRepetitionStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: "run") {
        } else if result.policyApprovalRequired {
            run.status = .failed
            run.stopReason = "permission_approval_required"
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                type: "permission.approval.requested",
                payload: result.policyApprovalMessage ?? "The provider needs a runtime permission before it can continue.",
                run: run
            )
            modelContext.insert(event)
        } else if result.policyViolation {
            run.status = .failed
            run.stopReason = "policy_violation"
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                type: "error",
                payload: result.policyViolationMessage ?? "ASTRA stopped the provider because observed activity violated the run policy.",
                run: run
            )
            modelContext.insert(event)
        } else if AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.stopReason = "max_budget_reached"
            task.status = .budgetExceeded
            let reason = "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "reason": "max_budget_reached",
                "tokens_used": String(task.tokensUsed),
                "token_budget": String(task.tokenBudget)
            ], level: .error)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            AgentRuntimeBudgetPolicy.recordFinalBudgetWarningIfNeeded(
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
                Self.applyManualCompletion(
                    task: task,
                    run: run,
                    modelContext: modelContext,
                    successPayload: "Agent finished."
                )

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
            ) ?? AgentRuntimeFailurePayload.enriched(
                prefix: "Agent exited with code \(result.exitCode).",
                rawError: result.error,
                task: task
            )
            let event = TaskEvent(task: task, type: "error",
                                  payload: payload, run: run)
            modelContext.insert(event)
        }

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: task.goal
        )

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
            TaskCapabilitySnapshotter.capture(for: nextTask)
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

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "run"
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
        guard AgentRuntimeLaunchPreflight.prepareTaskFolderForLaunch(
            task,
            modelContext: modelContext,
            phase: "resume"
        ) else {
            isRunning = false
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

        guard await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "resume",
            contextText: message
        ) else {
            isRunning = false
            return
        }

        // Build a fresh prompt with session history instead of --resume (which resends full conversation).
        // This cuts input tokens by ~90% on follow-ups.
        let followUpPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: message, task: task)
        logContextPromptDiagnostics(for: task, prompt: followUpPrompt, phase: "resume")
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: followUpPrompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "resume",
            runtime: .claudeCode,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            isRunning = false
            return
        }
        Self.logCapabilityResolution(for: task, runtime: .claudeCode, phase: "resume")
        await logGitHubCLIPreflightIfNeeded(for: task, phase: "resume")
        let runPermissionPolicy = effectivePermissionPolicy(for: task, executionPolicy: executionPolicy)
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: task.model,
            workspacePath: TaskWorkspaceAccess(task: task).codeWorkingDirectory,
            phase: "resume",
            permissionPolicy: runPermissionPolicy,
            executionPolicy: executionPolicy,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            modelContext: modelContext
        )
        guard shouldStartProvider(with: manifest, task: task, run: run, modelContext: modelContext, phase: "resume") else {
            return
        }
        let launchExecutionPolicy = executionPolicy.applyingProviderRender(manifest.providerRender)

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
            workspacePath: TaskWorkspaceAccess(task: task).codeWorkingDirectory,
            claudePath: claudePath,
            permissionPolicy: runPermissionPolicy,
            executionPolicy: launchExecutionPolicy,
            permissionManifest: manifest,
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
            AgentRuntimeStreamDiagnostics.logStreamDebug(
                snapshot: streamDebugCapture.snapshot(),
                runtime: .claudeCode,
                task: task,
                run: run,
                phase: "resume",
                exitCode: result.exitCode
            )
        }

        let failureDiagnostic = (result.exitCode == 0 || result.runtimeStopped || result.repetitionKilled) ? nil : AgentRuntimeFailureDiagnostic.classify(
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
        } else if applyRuntimeStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: "resume") {
        } else if applyRepetitionStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: "resume") {
        } else if result.policyApprovalRequired {
            run.status = .failed
            run.stopReason = "permission_approval_required"
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                type: "permission.approval.requested",
                payload: result.policyApprovalMessage ?? "The provider needs a runtime permission before it can continue.",
                run: run
            )
            modelContext.insert(event)
        } else if result.policyViolation {
            run.status = .failed
            run.stopReason = "policy_violation"
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                type: "error",
                payload: result.policyViolationMessage ?? "ASTRA stopped the provider because observed activity violated the run policy.",
                run: run
            )
            modelContext.insert(event)
        } else if AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.stopReason = "max_budget_reached"
            task.status = .budgetExceeded
            let reason = "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
            modelContext.insert(event)
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
                "phase": "resume",
                "reason": "max_budget_reached",
                "tokens_used": String(task.tokensUsed),
                "token_budget": String(task.tokenBudget)
            ], level: .error)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            AgentRuntimeBudgetPolicy.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: "resume",
                budgetEnforcementMode: budgetEnforcementMode
            )
            Self.applyManualCompletion(
                task: task,
                run: run,
                modelContext: modelContext,
                successPayload: "Follow-up completed."
            )
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
                ) ?? AgentRuntimeFailurePayload.enriched(
                    prefix: "Follow-up failed (exit \(result.exitCode)).",
                    rawError: result.error,
                    task: task
                )
                let event = TaskEvent(task: task, type: "error",
                                      payload: payload, run: run)
                modelContext.insert(event)
            }
            task.status = .failed
        }

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: message
        )

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: "resume"
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
        guard AgentRuntimeLaunchPreflight.prepareTaskFolderForLaunch(
            task,
            modelContext: modelContext,
            phase: auditPhase
        ) else {
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

        guard await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            contextText: promptOverride ?? startPayload
        ) else {
            isRunning = false
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

        let codeDir = TaskWorkspaceAccess(task: task).codeWorkingDirectory
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
            if executionPath != TaskWorkspaceAccess(task: task).effectiveWorkspacePath {
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
        logContextPromptDiagnostics(for: task, prompt: prompt, phase: auditPhase)
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            runtime: .copilotCLI,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            isRunning = false
            return
        }
        Self.logCapabilityResolution(for: task, runtime: .copilotCLI, phase: auditPhase)
        await logGitHubCLIPreflightIfNeeded(for: task, phase: auditPhase)
        let copilotCapabilities = CopilotCLIRuntime.capabilities(executablePath: copilotPath)
        let runPermissionPolicy = effectivePermissionPolicy(for: task, executionPolicy: executionPolicy)
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .copilotCLI,
            model: task.model,
            workspacePath: executionPath,
            phase: auditPhase,
            permissionPolicy: runPermissionPolicy,
            executionPolicy: executionPolicy,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            copilotCapabilities: copilotCapabilities,
            modelContext: modelContext
        )
        guard shouldStartProvider(with: manifest, task: task, run: run, modelContext: modelContext, phase: auditPhase) else {
            IsolationService.cleanup(task: task, executionPath: executionPath)
            return
        }
        let launchExecutionPolicy = executionPolicy.applyingProviderRender(manifest.providerRender)
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
            permissionPolicy: runPermissionPolicy,
            executionPolicy: launchExecutionPolicy,
            permissionManifest: manifest,
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
        recordCopilotSessionMetricsIfNeeded(
            copilotHome: copilotHome,
            task: task,
            run: run,
            runStartedAt: startTime,
            modelContext: modelContext,
            recordingState: recordingState,
            onEvent: onEvent
        )
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
        AgentRuntimeStreamDiagnostics.logCopilotStreamTelemetry(
            snapshot: streamSnapshot,
            task: task,
            run: run,
            phase: auditPhase,
            exitCode: result.exitCode
        )
        if let streamDebugCapture {
            AgentRuntimeStreamDiagnostics.logStreamDebug(
                snapshot: streamDebugCapture.snapshot(),
                runtime: .copilotCLI,
                task: task,
                run: run,
                phase: auditPhase,
                exitCode: result.exitCode
            )
        }
        let failureDiagnostic = (result.exitCode == 0 || result.runtimeStopped || result.repetitionKilled) ? nil : AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: task.model,
            exitCode: result.exitCode,
            rawError: result.error,
            providerVersion: result.providerVersion,
            stream: streamSnapshot,
            timedOut: result.timedOut,
            budgetExceeded: result.budgetExceeded,
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
        } else if applyRuntimeStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: auditPhase) {
        } else if applyRepetitionStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: auditPhase) {
        } else if result.policyApprovalRequired {
            run.status = .failed
            run.stopReason = "permission_approval_required"
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                type: "permission.approval.requested",
                payload: result.policyApprovalMessage ?? "The provider needs a runtime permission before it can continue.",
                run: run
            )
            modelContext.insert(event)
        } else if result.policyViolation {
            run.status = .failed
            run.stopReason = "policy_violation"
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                type: "error",
                payload: result.policyViolationMessage ?? "ASTRA stopped the provider because observed activity violated the run policy.",
                run: run
            )
            modelContext.insert(event)
        } else if AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.stopReason = "max_budget_reached"
            task.status = .budgetExceeded
            let reason = "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, type: "budget.exceeded",
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
            modelContext.insert(event)
        } else if result.exitCode == 0 {
            run.status = .completed
            run.stopReason = "completed"
            AgentRuntimeBudgetPolicy.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: auditPhase,
                budgetEnforcementMode: budgetEnforcementMode
            )
            switch task.validationStrategy {
            case .manual:
                Self.applyManualCompletion(
                    task: task,
                    run: run,
                    modelContext: modelContext,
                    successPayload: "Copilot finished."
                )
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
            ) ?? AgentRuntimeFailurePayload.enriched(
                prefix: "Copilot exited with code \(result.exitCode).",
                rawError: result.error,
                task: task
            )
            let event = TaskEvent(task: task, type: "error", payload: payload, run: run)
            modelContext.insert(event)
        }

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: promptOverride == nil ? task.goal : (startEventPayload ?? task.goal)
        )

        IsolationService.cleanup(task: task, executionPath: executionPath)
        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase
        )
        isRunning = false
    }

    @MainActor
    func cancel() {
        cancellationRequested = true
        processRunner.cancel()
    }

    // MARK: - Private

    @MainActor
    private static func applyManualCompletion(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        successPayload: String
    ) {
        if TaskDeliverableExpectation.requiresStandaloneArtifact(task),
           !TaskDeliverableExpectation.hasArtifact(for: task, run: run) {
            run.status = .failed
            run.stopReason = "no_usable_result"
            task.status = .pendingUser
            task.completedAt = nil
            let event = TaskEvent(
                task: task,
                type: "error",
                payload: TaskDeliverableExpectation.missingArtifactMessage(for: task),
                run: run
            )
            modelContext.insert(event)
            return
        }

        task.status = .completed
        let event = TaskEvent(task: task, type: "task.completed", payload: successPayload, run: run)
        modelContext.insert(event)
    }

    @MainActor
    private func logContextPromptDiagnostics(for task: AgentTask, prompt: String, phase: String) {
        AppLogger.audit(
            .contextPromptDiagnostics,
            category: "Worker",
            taskID: task.id,
            fields: TaskContextStateManager.promptDiagnosticsFields(
                task: task,
                prompt: prompt,
                phase: phase
            ),
            level: .debug
        )
    }

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

    @MainActor
    private func recordCopilotSessionMetricsIfNeeded(
        copilotHome: String,
        task: AgentTask,
        run: TaskRun,
        runStartedAt: Date,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState,
        onEvent: @escaping (ParsedEvent) -> Void
    ) {
        guard run.tokensUsed == 0,
              let metrics = CopilotSessionMetricsReader.finalMetrics(
                copilotHome: copilotHome,
                taskID: task.id,
                runStartedAt: runStartedAt
              ) else {
            return
        }

        AgentEventRecorder.recordCopilotEvent(
            metrics.event,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
        if let parsed = AgentEventRecorder.parsedEvent(from: metrics.event) {
            onEvent(parsed)
        }
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "source": "copilot_session_state",
            "session_id_prefix": String(metrics.sessionID.prefix(8)),
            "tokens_total": String(metrics.totalTokens),
            "tokens_input": String(metrics.inputTokens),
            "tokens_output": String(metrics.outputTokens),
            "turns": metrics.turns.map(String.init) ?? "unknown",
            "duration_ms": metrics.durationMs.map(String.init) ?? "unknown"
        ])
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
    private func shouldStartProvider(
        with manifest: RunPermissionManifest,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        let blockedDiagnostics = manifest.providerRender.diagnostics.filter { $0.severity == .blocked }
        guard !blockedDiagnostics.isEmpty else { return true }

        run.status = .failed
        run.completedAt = Date()
        run.stopReason = "policy_blocked"
        task.status = .pendingUser
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)

        let details = blockedDiagnostics
            .map { diagnostic in
                let remediation = diagnostic.remediation.map { " Remediation: \($0)" } ?? ""
                return "- \(diagnostic.title): \(diagnostic.message)\(remediation)"
            }
            .joined(separator: "\n")
        modelContext.insert(TaskEvent(
            task: task,
            type: "error",
            payload: "Provider policy blocked this run before launch.\n\(details)",
            run: run
        ))
        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: modelContext)
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: AgentRuntimeRunPersistence.fields(task: task, run: run, phase: phase)
        )
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "reason": "policy_blocked",
            "phase": phase,
            "blocked_diagnostics": String(blockedDiagnostics.count),
            "policy_level": manifest.policyLevel.rawValue,
            "runtime": manifest.providerID.rawValue
        ], level: .warning)
        isRunning = false
        return false
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
            "connector_service_types": compactNames(connectors.map(\.serviceType)),
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
        var tools = Set(TaskCapabilityResolver(task: task).resolver.resolvedProviderAllowedTools)
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

    @MainActor
    private func applyRuntimeStopIfNeeded(
        _ result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        guard let reason = result.runtimeStopReason, !reason.isEmpty else { return false }

        run.status = .failed
        run.stopReason = reason
        task.status = Self.isTerminalRuntimeStop(reason) ? .failed : .pendingUser

        let payload = result.runtimeStopMessage
            ?? "ASTRA stopped the provider because browser control reached a terminal guardrail: \(reason)."
        modelContext.insert(TaskEvent(task: task, type: "error", payload: payload, run: run))
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "phase": phase,
            "reason": reason,
            "source": "runtime_stop"
        ], level: .error)
        return true
    }

    private static func isTerminalRuntimeStop(_ reason: String) -> Bool {
        switch reason {
        case "provider_permission_denied_broad_permissions",
             "provider_permission_unresumable",
             "provider_no_semantic_progress":
            return true
        default:
            return false
        }
    }

    @MainActor
    private func applyRepetitionStopIfNeeded(
        _ result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        guard result.repetitionKilled else { return false }

        run.status = .failed
        run.stopReason = "repetition_detected"
        task.status = .failed

        modelContext.insert(TaskEvent(
            task: task,
            type: "error",
            payload: "Repetition loop detected. ASTRA stopped the provider after repeated identical runtime events.",
            run: run
        ))
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "phase": phase,
            "reason": "repetition_detected",
            "source": "runtime_repetition_guard"
        ], level: .error)
        return true
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

    @MainActor
    private func effectivePermissionPolicy(
        for task: AgentTask,
        executionPolicy: AgentRuntimeExecutionPolicy
    ) -> PermissionPolicy {
        if skipPermissions {
            return .autonomous
        }
        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: AgentPolicyLevel.normalized(defaultAgentPolicyLevelRaw),
            fallbackPermissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy
        )
        return PermissionPolicy.fromAgentPolicyLevel(resolution.level)
    }

    /// Model used for AI validation checks
    var validationModel: String = "claude-haiku-4-5-20251001"

    /// Maximum execution time in seconds (10 minutes default)
    var timeoutSeconds: TimeInterval = 600

    /// Permission policy applied to CLI runs. Review/restricted is the safe default;
    /// the composer security gate can opt into autonomous runs for trusted work.
    var skipPermissions: Bool = false
    var permissionPolicy: PermissionPolicy = .restricted

}
