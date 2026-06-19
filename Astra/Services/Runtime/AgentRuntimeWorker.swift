import Foundation
import SwiftData
import ASTRACore

@Observable
final class AgentRuntimeWorker {
    private(set) var isRunning = false
    private var cancellationRequested = false
    private var runtimeConfiguration = AgentRuntimeConfiguration()
    private let processRunner: AgentRuntimeProcessRunner
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

    func setExecutablePath(_ path: String, for runtime: AgentRuntimeID) {
        runtimeConfiguration.setExecutablePath(path, for: runtime)
    }

    func executablePath(for runtime: AgentRuntimeID) -> String {
        runtimeConfiguration.executablePath(for: runtime)
    }

    func setHomeDirectory(_ path: String, for runtime: AgentRuntimeID) {
        runtimeConfiguration.setHomeDirectory(path, for: runtime)
    }

    func homeDirectory(for runtime: AgentRuntimeID) -> String {
        runtimeConfiguration.homeDirectory(for: runtime)
    }

    func setProviderSettings(_ settings: AgentRuntimeProviderSettings) {
        runtimeConfiguration.setProviderSettings(settings)
    }

    var defaultRuntimeID: AgentRuntimeID {
        get { runtimeConfiguration.defaultRuntimeID }
        set { runtimeConfiguration.defaultRuntimeID = newValue }
    }

    var defaultAgentPolicyLevelRaw: String = AgentPolicyLevel.review.rawValue
    @MainActor init(processRunner: AgentRuntimeProcessRunner = AgentRuntimeProcessRunner()) {
        self.processRunner = processRunner
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
        TaskCapabilitySnapshotter.refreshForFreshRun(task: task)
        await executeRuntimeSession(
            task: task,
            modelContext: modelContext,
            selectedRuntime: selectedRuntime,
            onEvent: onEvent,
            promptOverride: promptOverride,
            startEventPayload: startEventPayload,
            auditPhase: "run",
            recordingMode: .initial,
            executionPolicy: executionPolicy
        )
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
            guard await validateApprovedPlanContractForFinalCompletion(
                task: task,
                plan: currentPlan,
                modelContext: modelContext
            ) else {
                return
            }
            TaskPlanService.recordExecutionCompleted(planID: currentPlan.planID, task: task, modelContext: modelContext)
            task.status = .completed
            task.updatedAt = Date()
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            return
        }

        guard TaskExecutionArtifactPreparer.prepareTaskOutputArtifacts(
            task: task,
            plan: currentPlan,
            step: approvedStep,
            modelContext: modelContext,
            phase: "approved_plan"
        ) else {
            TaskPlanService.recordExecutionFailed(
                planID: currentPlan.planID,
                task: task,
                modelContext: modelContext,
                reason: "artifact_preflight_failed"
            )
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
                await finalizeApprovedPlanStep(
                    approvedStep,
                    plan: currentPlan,
                    task: task,
                    modelContext: modelContext
                )
            } else {
                await finalizeApprovedFullPlan(
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
    ) async {
        let stateAfterRun = TaskPlanService.reconstruct(for: task)
        let currentStepStatus = stateAfterRun.plan?.steps.first(where: { $0.id == step.id })?.status
        let lastRun = task.runs.sorted { $0.startedAt < $1.startedAt }.last

        // Checkpoint: a finished process is a claim, not evidence. Resolve the
        // step's declared required outputs before recording it done — even a
        // provider-emitted completion marker doesn't outrank a missing output.
        // Provider-skipped steps are exempt (their outputs legitimately don't
        // exist), and a provider-reported blocker takes priority below so its
        // actionable detail isn't shadowed by a generic checkpoint message.
        let checkpoint = PlanStepCheckpointVerifier.verify(step: step, plan: plan, task: task)
        let latestBlockIsCheckpointImposed = PlanStepCheckpointVerifier.latestBlockIsCheckpointImposed(
            task: task,
            stepID: step.id
        )
        let providerReportedBlock = currentStepStatus == .blocked && !latestBlockIsCheckpointImposed
        if currentStepStatus != .skipped, !providerReportedBlock, !checkpoint.missingRequiredPaths.isEmpty {
            let message = PlanStepCheckpointVerifier.recordCheckpointBlock(
                step: step,
                missing: checkpoint.missingRequiredPaths,
                plan: plan,
                task: task,
                run: lastRun,
                modelContext: modelContext
            )
            pauseApprovedPlanForUser(task: task, modelContext: modelContext, message: message, run: lastRun)
            return
        }

        let shouldFallbackComplete: Bool = {
            switch currentStepStatus {
            case .done, .skipped:
                return false
            case .blocked:
                // Only ASTRA's own checkpoint blocks are liftable by evidence:
                // a retried step whose required outputs now exist completes.
                // Provider-reported blockers carry meaning the filesystem
                // can't refute and still need an explicit completion marker.
                return latestBlockIsCheckpointImposed
                    && checkpoint.isVerified
                    && !checkpoint.verifiedPaths.isEmpty
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
                run: lastRun,
                title: step.title,
                summary: "Completed approved step: \(step.title).\(checkpoint.completionEvidence)"
            )
        } else if currentStepStatus == .done, !checkpoint.verifiedPaths.isEmpty {
            // The provider's own completion marker recorded the step; keep the
            // checkpoint's evidence in the log alongside it.
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.info,
                payload: "Step checkpoint verified for \"\(step.title)\":\(checkpoint.completionEvidence)",
                run: lastRun
            ))
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
            guard await validateApprovedPlanContractForFinalCompletion(
                task: task,
                plan: refreshedPlan,
                modelContext: modelContext
            ) else {
                return
            }
            TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
        }
    }

    @MainActor
    private func finalizeApprovedFullPlan(
        _ plan: TaskPlanPayload,
        task: AgentTask,
        modelContext: ModelContext
    ) async {
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

        // Single-run plans have no intermediate run boundaries, so the output
        // checkpoint for every step lands here instead.
        let lastRun = task.runs.sorted(by: { $0.startedAt < $1.startedAt }).last
        if let message = PlanStepCheckpointVerifier.recordFullPlanCheckpointBlocks(
            plan: refreshedPlan,
            task: task,
            run: lastRun,
            modelContext: modelContext
        ) {
            pauseApprovedPlanForUser(task: task, modelContext: modelContext, message: message, run: lastRun)
            return
        }

        guard await validateApprovedPlanContractForFinalCompletion(
            task: task,
            plan: refreshedPlan,
            modelContext: modelContext
        ) else {
            return
        }
        TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
    }

    @MainActor
    private func validateApprovedPlanContractForFinalCompletion(
        task: AgentTask,
        plan: TaskPlanPayload,
        modelContext: ModelContext
    ) async -> Bool {
        let contractEvaluation = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: task.runs.sorted { $0.startedAt < $1.startedAt }.last,
            modelContext: modelContext,
            verifierRuntime: utilityRuntimeConfiguration(
                for: .verifier,
                task: task,
                fallbackRuntime: runtimeConfiguration.selectedRuntime(for: task),
                preferredModel: validationModel,
                modelContext: modelContext
            )
        )
        let decision = TaskCompletionPolicy.decide(validationContract: contractEvaluation)
        guard decision.canComplete else {
            let run = task.runs.sorted { $0.startedAt < $1.startedAt }.last
            run?.status = .failed
            run?.typedStopReason = decision.typedStopReason ?? TaskRunStopReason.custom(TaskCompletionPolicyGate.validationContract.rawValue)
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: decision.userVisibleMessage ?? contractEvaluation.summary,
                run: run
            )
            return false
        }
        return true
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
            eventType: TaskEventTypes.System.info,
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
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: message, task: task)
        await executeRuntimeSession(
            task: task,
            modelContext: modelContext,
            selectedRuntime: selectedRuntime,
            onEvent: onEvent,
            promptOverride: prompt,
            startEventType: "user.message",
            startEventPayload: message,
            sessionMessage: message,
            auditPhase: "resume",
            recordingMode: .followUp,
            executionPolicy: executionPolicy
        )
    }

    @MainActor
    private func executeRuntimeSession(
        task: AgentTask,
        modelContext: ModelContext,
        selectedRuntime: AgentRuntimeID,
        onEvent: @escaping (ParsedEvent) -> Void,
        promptOverride: String? = nil,
        startEventType: String = "task.started",
        startEventPayload: String? = nil,
        sessionMessage: String? = nil,
        auditPhase: String = "run",
        recordingMode: AgentRuntimeRecordingMode = .initial,
        executionPolicy: AgentRuntimeExecutionPolicy = .default
    ) async {
        let runtimeAdapter = AgentRuntimeAdapterRegistry.adapter(for: selectedRuntime)
        let launchSettings = runtimeAdapter.launchSettings(configuration: runtimeConfiguration)
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "status": task.status.rawValue,
            "model": task.model,
            "runtime": selectedRuntime.rawValue,
            "phase": auditPhase,
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])
        if auditPhase == "resume" {
            AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
                "mode": task.sessionId == nil ? "fresh_follow_up" : "session_follow_up",
                "runtime": selectedRuntime.rawValue,
                "message_length": String(sessionMessage?.count ?? 0),
                "prompt_chars": String(promptOverride?.count ?? 0),
                "history_run_count": String(task.runs.count),
                "history_output_chars": String(task.runs.reduce(0) { $0 + $1.output.count }),
                "has_session_id": String(task.hasProviderSession),
                "supports_native_continuation": String(runtimeAdapter.descriptor.supportsNativeContinuation),
                "uses_native_continuation": "pending",
                "continuation_mode": "pending_launch_signature",
                "native_session_prefix": task.sessionId.map { String($0.prefix(8)) } ?? "none",
                "workspace_id": task.workspace?.id.uuidString ?? "none"
            ])
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
            phase: auditPhase
        ) else {
            return
        }
        isRunning = true
        cancellationRequested = false

        if task.runtimeID == nil {
            task.runtimeID = selectedRuntime.rawValue
        }
        task.status = .running
        task.updatedAt = Date()
        task.markRead()

        let run = TaskRun(task: task)
        run.runtimeID = selectedRuntime.rawValue
        modelContext.insert(run)

        let startPayload = startEventPayload ?? runtimeAdapter.defaultStartEventPayload(task: task)
        let startEvent = TaskEvent(task: task, type: startEventType, payload: startPayload, run: run)
        modelContext.insert(startEvent)

        let providerLaunchContextText = runtimeAdapter.connectorPreflightContextText(
            task: task,
            promptOverride: promptOverride,
            startPayload: startPayload,
            sessionMessage: sessionMessage,
            phase: auditPhase
        )

        guard FileManager.default.isExecutableFile(atPath: launchSettings.executablePath) else {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": runtimeAdapter.missingExecutableAuditReason(),
                "runtime": selectedRuntime.rawValue
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            if let stopReason = runtimeAdapter.missingExecutableStopReason() {
                run.typedStopReason = TaskRunStopReason.custom(stopReason)
            }
            task.status = .failed
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                payload: runtimeAdapter.missingExecutableMessage(executablePath: launchSettings.executablePath), run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        guard await AgentRuntimeLaunchPreflight.preflightRuntimeReadinessBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            configuration: runtimeReadinessConfiguration(for: selectedRuntime), readinessService: runtimeReadinessService
        ) else {
            isRunning = false
            return
        }

        guard await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            contextText: providerLaunchContextText
        ) else {
            isRunning = false
            return
        }

        _ = AgentRuntimeLaunchPreflight.preflightRemoteWorkspaceBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            runtime: selectedRuntime
        )

        let codeDir = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        var isDir: ObjCBool = false
        let workspaceExists = FileManager.default.fileExists(atPath: codeDir, isDirectory: &isDir) && isDir.boolValue
        if runtimeAdapter.shouldCheckWorkspaceDirectory(phase: auditPhase),
           !workspaceExists {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "workspace_not_found",
                "runtime": selectedRuntime.rawValue
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            run.typedStopReason = .workspaceNotFound
            task.status = .failed
            task.updatedAt = Date()
            task.markUnreadForCurrentStatus(at: task.updatedAt)
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                payload: "Workspace directory not found: \(codeDir)", run: run)
            modelContext.insert(event)
            isRunning = false
            return
        }

        let executionPath: String
        let shouldCleanupIsolation: Bool
        if runtimeAdapter.shouldPrepareIsolation(phase: auditPhase) {
            do {
                executionPath = try await IsolationService.prepare(task: task)
                shouldCleanupIsolation = true
                if executionPath != TaskWorkspaceAccess(task: task).effectiveWorkspacePath {
                    let isoEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use,
                        payload: "Isolation: \(task.isolationStrategy.rawValue) -> \(executionPath)", run: run)
                    modelContext.insert(isoEvent)
                }
            } catch {
                AppLogger.audit(.isolationFailed, category: "Isolation", taskID: task.id, fields: [
                    "error_type": String(describing: type(of: error)),
                    "runtime": selectedRuntime.rawValue
                ], level: .error)
                run.status = .failed
                run.completedAt = Date()
                run.typedStopReason = .isolationFailed
                task.status = .failed
                task.updatedAt = Date()
                task.markUnreadForCurrentStatus(at: task.updatedAt)
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                    payload: "Workspace isolation failed: \(error.localizedDescription)", run: run)
                modelContext.insert(event)
                isRunning = false
                return
            }
        } else {
            executionPath = codeDir
            shouldCleanupIsolation = false
        }

        let executionEnvironment = DockerExecutionPlanner.snapshotForRun(
            task: task,
            currentDirectory: executionPath
        )
        let executionEnvironmentJSON = ExecutionEnvironmentStore.encode(executionEnvironment)
        task.executionEnvironmentSnapshotJSON = executionEnvironmentJSON
        run.executionEnvironmentSnapshotJSON = executionEnvironmentJSON

        let prompt = promptOverride ?? buildPrompt(for: task)
        logContextPromptDiagnostics(for: task, prompt: prompt, phase: auditPhase)
        let budgetEnforcementMode = currentBudgetEnforcementMode
        guard AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            runtime: selectedRuntime,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            isRunning = false
            return
        }
        AgentRuntimeCapabilityLaunchAudit.logResolution(
            for: task,
            runtime: selectedRuntime,
            phase: auditPhase,
            contextText: providerLaunchContextText
        )
        await AgentRuntimeCapabilityLaunchAudit.logGitHubCLIPreflightIfNeeded(
            for: task,
            runtime: selectedRuntime,
            phase: auditPhase,
            contextText: providerLaunchContextText
        )
        let policyRenderer = AgentRuntimeAdapterRegistry.policyRenderer(for: selectedRuntime)
        let providerCapabilities = policyRenderer.policyCapabilities(executablePath: launchSettings.executablePath)
        let runPermissionPolicy = effectivePermissionPolicy(for: task, executionPolicy: executionPolicy)
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: selectedRuntime,
            model: task.model,
            workspacePath: executionPath,
            phase: auditPhase,
            permissionPolicy: runPermissionPolicy,
            executionPolicy: executionPolicy,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            providerCapabilities: providerCapabilities,
            contextText: providerLaunchContextText,
            modelContext: modelContext
        )
        guard shouldStartProvider(with: manifest, task: task, run: run, modelContext: modelContext, phase: auditPhase) else {
            if shouldCleanupIsolation {
                IsolationService.cleanup(task: task, executionPath: executionPath)
            }
            return
        }
        let launchSignature = Self.providerLaunchSignature(
            for: task,
            manifest: manifest,
            contextText: providerLaunchContextText
        )
        let nativeContinuationDecision = Self.nativeContinuationSessionID(
            for: task,
            currentRun: run,
            runtimeAdapter: runtimeAdapter,
            phase: auditPhase,
            currentLaunchSignature: launchSignature,
            grantNeutralizingStrings: Self.signatureGrantStrings(for: manifest)
        )
        Self.recordProviderLaunchSignature(
            launchSignature,
            task: task,
            run: run,
            modelContext: modelContext
        )
        let nativeContinuationSessionID = nativeContinuationDecision.sessionID
        if auditPhase == "resume" {
            AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
                "mode": task.sessionId == nil ? "fresh_follow_up" : "session_follow_up",
                "runtime": selectedRuntime.rawValue,
                "supports_native_continuation": String(runtimeAdapter.descriptor.supportsNativeContinuation),
                "uses_native_continuation": String(nativeContinuationSessionID != nil),
                "continuation_mode": nativeContinuationSessionID == nil ? "rebuilt_prompt" : "native_plus_rebuilt_prompt",
                "native_continuation_skip_reason": nativeContinuationDecision.skipReason,
                "launch_signature_matched": String(nativeContinuationDecision.signatureMatched),
                "native_session_prefix": nativeContinuationSessionID.map { String($0.prefix(8)) } ?? "none",
                "workspace_id": task.workspace?.id.uuidString ?? "none"
            ], level: nativeContinuationSessionID == nil ? .debug : .info)
        }
        let launchExecutionPolicy = executionPolicy.applyingProviderRender(manifest.providerRender)
        let startTime = Date()
        let beforeGitStatus = runtimeAdapter.recordsInferredFileChanges
            ? AgentFileChangeDetector.gitStatusSnapshot(workspacePath: executionPath)
            : nil
        let beforeDirtyFingerprints = beforeGitStatus.map {
            AgentFileChangeDetector.fileFingerprints(
                for: AgentFileChangeDetector.absolutePaths(fromGitStatus: $0, workspacePath: executionPath),
                workspacePath: executionPath
            )
        }
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope(contextText: providerLaunchContextText)
        if !capabilityScope.behaviorSkills.isEmpty {
            let skillNames = capabilityScope.behaviorSkills.map(\.name).joined(separator: ", ")
            let skillEvent = TaskEvent(task: task, eventType: TaskEventTypes.System.skillActive,
                payload: "Active skills: \(skillNames)", run: run)
            modelContext.insert(skillEvent)
        }

        let pendingEvents = OrderedMainActorTaskQueue()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: runtimeAdapter.descriptor.supportsAstraRunProtocol
        )
        let recordingState = AgentEventRecordingState()
        let streamTelemetry = runtimeAdapter.recordsStreamTelemetry ? AgentRuntimeStreamTelemetry() : nil
        let streamDebugCapture = AgentRuntimeStreamDebugCapture.makeIfEnabled()
        let semanticProgressTimeout = AgentRuntimeProgressTimeoutPolicy.semanticProgressTimeout(
            task: task,
            phase: auditPhase,
            idleTimeoutSeconds: timeoutSeconds
        )
        let result = await processRunner.runRuntimeProcess(
            adapter: runtimeAdapter,
            prompt: prompt,
            task: task,
            workspacePath: executionPath,
            executablePath: launchSettings.executablePath,
            homeDirectory: launchSettings.homeDirectory,
            permissionPolicy: runPermissionPolicy,
            executionPolicy: launchExecutionPolicy,
            permissionManifest: manifest,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            phase: auditPhase,
            contextText: providerLaunchContextText,
            nativeContinuationSessionID: nativeContinuationSessionID,
            runID: run.id,
            liveApprovalsEnabled: liveApprovalsEnabled,
            noSemanticProgressTimeoutSeconds: semanticProgressTimeout,
            onInteractiveAsk: Self.interactiveAskHandler(
                runtime: selectedRuntime, task: task, run: run,
                permissionPolicy: runPermissionPolicy, manifest: manifest,
                modelContext: modelContext, pendingEvents: pendingEvents
            ),
            onLine: { line, parsesJSONLines in
                PerformanceSignposts.processStreamLine {
                    streamTelemetry?.recordRawLine(parsesJSONLines: parsesJSONLines)
                    streamDebugCapture?.recordLine(line, parsesJSONLines: parsesJSONLines)
                    let parsedBatch = PerformanceSignposts.parseProviderStream {
                        runtimeAdapter.parseWorkerStreamEvents(line: line, parsesJSONLines: parsesJSONLines)
                    }
                    parsedBatch.recordParsed(to: streamTelemetry)
                    parsedBatch.recordParsed(to: streamDebugCapture, rawLine: line)
                    let emittedEvents = parsedBatch.events.flatMap {
                        runtimeAdapter.processWorkerStreamEvent($0, pipeline: eventPipeline)
                    }
                    let emittedBatch = AgentRuntimeStreamEventBatch(
                        representation: parsedBatch.representation,
                        events: emittedEvents
                    )
                    emittedBatch.recordEmitted(to: streamTelemetry)
                    emittedBatch.recordEmitted(to: streamDebugCapture)
                    for filtered in emittedEvents {
                        pendingEvents.add { [weak self] in
                            guard self != nil else { return }
                            PerformanceSignposts.persistProviderEvent {
                                runtimeAdapter.recordWorkerStreamEvent(
                                    filtered,
                                    mode: recordingMode,
                                    task: task,
                                    run: run,
                                    modelContext: modelContext,
                                    recordingState: recordingState
                                )
                            }
                            if let parsed = runtimeAdapter.callbackEvent(from: filtered) {
                                onEvent(parsed)
                            }
                        }
                    }
                }
            }
        )
        let flushedBatch = runtimeAdapter.flushWorkerStreamEvents(pipeline: eventPipeline)
        flushedBatch.recordEmitted(to: streamTelemetry)
        flushedBatch.recordEmitted(to: streamDebugCapture)
        for event in flushedBatch.events {
            pendingEvents.add { [weak self] in
                guard self != nil else { return }
                PerformanceSignposts.persistProviderEvent {
                    runtimeAdapter.recordWorkerStreamEvent(
                        event,
                        mode: recordingMode,
                        task: task,
                        run: run,
                        modelContext: modelContext,
                        recordingState: recordingState
                    )
                }
                if let parsed = runtimeAdapter.callbackEvent(from: event) {
                    onEvent(parsed)
                }
            }
        }
        await pendingEvents.drainAll()
        runtimeAdapter.recordPostProcessEvents(context: AgentRuntimePostProcessContext(
            homeDirectory: launchSettings.homeDirectory,
            task: task,
            run: run,
            runStartedAt: startTime,
            modelContext: modelContext,
            recordingState: recordingState,
            onEvent: onEvent
        ))
        Self.recordEstimatedUsageIfProviderDidNotReport(
            runtimeAdapter: runtimeAdapter,
            selectedRuntime: selectedRuntime,
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext
        )
        let streamSnapshot = streamTelemetry?.snapshot()

        if let beforeGitStatus, let beforeDirtyFingerprints {
            AgentFileChangeDetector.appendInferredFileChanges(
                to: run,
                task: task,
                modelContext: modelContext,
                workspacePath: executionPath,
                beforeGitStatus: beforeGitStatus,
                beforeDirtyFingerprints: beforeDirtyFingerprints,
                runStart: startTime
            )
        }

        run.completedAt = Date()
        run.exitCode = result.exitCode
        run.providerVersion = result.providerVersion
        streamDebugCapture?.recordStderr(result.error)
        if let streamSnapshot {
            runtimeAdapter.logStreamTelemetry(
                snapshot: streamSnapshot,
                task: task,
                run: run,
                phase: auditPhase,
                exitCode: result.exitCode
            )
        }
        if let streamDebugCapture {
            AgentRuntimeStreamDiagnostics.logStreamDebug(
                snapshot: streamDebugCapture.snapshot(),
                runtime: selectedRuntime,
                task: task,
                run: run,
                phase: auditPhase,
                exitCode: result.exitCode
            )
        }
        let processSucceeded = result.exitCode == 0 || result.terminatedAfterTerminalProgress
        let failureDiagnostic = (processSucceeded || result.runtimeStopped || result.repetitionKilled) ? nil : AgentRuntimeFailureDiagnostic.classify(
            runtime: selectedRuntime,
            model: task.model,
            exitCode: result.exitCode,
            rawError: result.error, runOutput: run.output,
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
            "runtime": selectedRuntime.rawValue,
            "phase": auditPhase,
            "terminated_after_terminal_progress": String(result.terminatedAfterTerminalProgress)
        ], level: processSucceeded ? .info : .warning)

        if cancellationRequested || task.status == .cancelled {
            run.status = .cancelled
            run.typedStopReason = .cancelled
            task.status = .cancelled
        } else if result.timedOut {
            run.status = .timeout
            run.typedStopReason = .timeout
            task.status = .failed
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                                  payload: runtimeAdapter.timeoutPayload(
                                    phase: auditPhase,
                                    timeoutSeconds: timeoutSeconds
                                  ), run: run)
            modelContext.insert(event)
        } else if result.maxTurnsExceeded {
            run.status = .budgetExceeded
            run.typedStopReason = .maxTurnsReached
            task.status = .budgetExceeded
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Budget.exceeded,
                                  payload: runtimeAdapter.maxTurnsPayload(phase: auditPhase, task: task), run: run)
            modelContext.insert(event)
        } else if applyRuntimeStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: auditPhase) {
        } else if applyRepetitionStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: auditPhase) {
        } else if result.policyApprovalRequired {
            run.status = .failed
            run.typedStopReason = .permissionApprovalRequired
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                eventType: TaskEventTypes.Tool.permissionApprovalRequested,
                payload: result.policyApprovalMessage ?? "The provider needs a runtime permission before it can continue.",
                run: run
            )
            modelContext.insert(event)
        } else if result.policyViolation {
            run.status = .failed
            run.typedStopReason = .policyViolation
            task.status = .pendingUser
            let event = TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: result.policyViolationMessage ?? "ASTRA stopped the provider because observed activity violated the run policy.",
                run: run
            )
            modelContext.insert(event)
        } else if AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            budget: AgentRuntimeBudgetSnapshot(task: task),
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.typedStopReason = .maxBudgetReached
            task.status = .budgetExceeded
            let reason = "Token budget exceeded"
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Budget.exceeded,
                                  payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)
            modelContext.insert(event)
        } else if processSucceeded,
                  runtimeAdapter.requiresVisibleResultForSuccessfulRun(phase: auditPhase),
                  Self.applyEmptySuccessfulRunIfNeeded(
                    runtimeAdapter: runtimeAdapter,
                    task: task,
                    run: run,
                    modelContext: modelContext,
                    result: result,
                    phase: auditPhase
                  ) {
        } else if processSucceeded {
            run.status = .completed
            run.typedStopReason = .completed
            AgentRuntimeBudgetPolicy.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: auditPhase,
                budgetEnforcementMode: budgetEnforcementMode
            )
            let blockedByDeliverableVerification = await Self.applyDeliverableVerificationFailureIfNeeded(
                task: task,
                run: run,
                modelContext: modelContext
            )
            if !blockedByDeliverableVerification {
                if runtimeAdapter.shouldValidateSuccessfulRun(phase: auditPhase) {
                    switch task.validationStrategy {
                    case .manual:
                        let completedManually = Self.applyManualCompletion(
                            task: task,
                            run: run,
                            modelContext: modelContext,
                            successPayload: runtimeAdapter.manualCompletionPayload(phase: auditPhase)
                        )
                        if completedManually {
                            await Self.applyAutomaticBaselineVerificationIfNeeded(
                                task: task,
                                run: run,
                                modelContext: modelContext
                            )
                        }
                    case .runTests:
                        let testEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Running validation tests...", run: run)
                        modelContext.insert(testEvent)
                        let testResult = await ValidationService.runTests(task: task)
                        switch testResult {
                        case .passed(let details):
                            task.status = .completed
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.completed, payload: "\(ValidationOutcomeMarker.testsPassed.rawValue). \(String(details.prefix(300)))", run: run)
                            modelContext.insert(event)
                        case .failed(let details):
                            task.status = .failed
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.testsFailed.rawValue):\n\(String(details.prefix(500)))", run: run)
                            modelContext.insert(event)
                        case .error(let msg):
                            task.status = .pendingUser
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.validationError.rawValue): \(msg). Needs manual review.", run: run)
                            modelContext.insert(event)
                        }
                    case .aiCheck:
                        let checkEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Running AI self-check...", run: run)
                        modelContext.insert(checkEvent)
                        let aiResult = await ValidationService.aiCheck(
                            task: task,
                            claudePath: claudePath,
                            model: validationModel,
                            utilityRuntime: utilityRuntimeConfiguration(
                                for: .verifier,
                                task: task,
                                fallbackRuntime: selectedRuntime,
                                preferredModel: validationModel,
                                modelContext: modelContext
                            )
                        )
                        switch aiResult {
                        case .passed(let details):
                            task.status = .completed
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.completed, payload: "\(ValidationOutcomeMarker.aiCheckPassed.rawValue). \(String(details.prefix(300)))", run: run)
                            modelContext.insert(event)
                        case .failed(let details):
                            task.status = .pendingUser
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.aiCheckFlagged.rawValue) issues:\n\(String(details.prefix(500)))", run: run)
                            modelContext.insert(event)
                        case .error(let msg):
                            task.status = .pendingUser
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.aiCheckError.rawValue): \(msg). Needs manual review.", run: run)
                            modelContext.insert(event)
                        }
                    }
                } else {
                    let completedManually = Self.applyManualCompletion(
                        task: task,
                        run: run,
                        modelContext: modelContext,
                        successPayload: runtimeAdapter.manualCompletionPayload(phase: auditPhase)
                    )
                    if completedManually {
                        await Self.applyAutomaticBaselineVerificationIfNeeded(
                            task: task,
                            run: run,
                            modelContext: modelContext
                        )
                    }
                }
            }
        } else if Self.shouldPauseForRuntimePermissionApproval(
            failureDiagnostic: failureDiagnostic,
            task: task,
            run: run
        ) {
            run.status = .failed
            run.typedStopReason = .permissionApprovalRequired
            task.status = .pendingUser
            let payload = permissionApprovalRequestPayload(
                diagnostic: failureDiagnostic,
                result: result
            )
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionApprovalRequested, payload: payload, run: run)
            modelContext.insert(event)
        } else {
            run.status = .failed
            run.typedStopReason = .failed
            if runtimeAdapter.shouldClearStaleSessionOnFailure(phase: auditPhase, result: result) {
                task.sessionId = nil
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                                      payload: "Session expired or not found. Session cleared - retry will start fresh.", run: run)
                modelContext.insert(event)
                AppLogger.audit(.workerSessionCleared, category: "Worker", taskID: task.id, fields: [
                    "reason": "stale_session",
                    "runtime": selectedRuntime.rawValue
                ], level: .warning)
            } else {
                let prefix = runtimeAdapter.failurePayloadPrefix(phase: auditPhase, exitCode: result.exitCode)
                let payload = failureDiagnostic?.userFacingPayload(
                    prefix: prefix
                ) ?? AgentRuntimeFailurePayload.enriched(
                    prefix: prefix,
                    rawError: result.error,
                    task: task
                )
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run)
                modelContext.insert(event)
            }
            task.status = .failed
        }

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: runtimeAdapter.sessionTurnMessage(
                task: task,
                promptOverride: promptOverride,
                startPayload: startEventPayload,
                sessionMessage: sessionMessage,
                phase: auditPhase
            )
        )

        if auditPhase == "run",
           task.status == .completed,
           runtimeAdapter.performsPostRunFollowUps(phase: auditPhase),
           !task.chainedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            createChainedTask(from: task, run: run, modelContext: modelContext)
        }

        if runtimeAdapter.performsPostRunFollowUps(phase: auditPhase) {
            scheduleGeneratedTitleIfNeeded(for: task, selectedRuntime: selectedRuntime, modelContext: modelContext)
        }

        if shouldCleanupIsolation {
            IsolationService.cleanup(task: task, executionPath: executionPath)
        }
        let handoffTaskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let handoffDiscoveredFiles = await TaskOutputDiscovery.filesAsync(in: handoffTaskFolder)
        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            handoffDiscoveredFiles: handoffDiscoveredFiles
        )
        isRunning = false
    }

    @MainActor
    func cancel() {
        cancellationRequested = true
        processRunner.cancel()
    }

    // MARK: - Private

    private func runtimeReadinessConfiguration(for runtime: AgentRuntimeID) -> RuntimeReadinessConfiguration {
        let providerSnapshot = RuntimeSettingsSnapshotStore.providerSnapshot()
        return RuntimeReadinessConfiguration(
            runtime: runtime,
            providerSettings: runtimeConfiguration.configuredProviderSettings,
            claudeProvider: providerSnapshot.claudeProvider,
            vertexProjectID: providerSnapshot.vertexProjectID,
            vertexRegion: providerSnapshot.vertexRegion,
            vertexOpusModel: providerSnapshot.vertexOpusModel,
            vertexSonnetModel: providerSnapshot.vertexSonnetModel,
            vertexHaikuModel: providerSnapshot.vertexHaikuModel
        )
    }

    @MainActor
    private static func applyEmptySuccessfulRunIfNeeded(
        runtimeAdapter: any AgentRuntimePostRunDiagnostics,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        result: AgentProcessResult,
        phase: String
    ) -> Bool {
        let visibleOutput = !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visibleFileResult = TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: run)
        guard !visibleOutput, !visibleFileResult else {
            return false
        }

        run.status = .failed
        run.typedStopReason = .noUsableResult
        task.status = .pendingUser
        task.completedAt = nil

        let providerName = runtimeAdapter.descriptor.displayName
        let requiredArtifact = TaskDeliverableExpectation.requiresDeliverableArtifact(task)
        let antigravityDiagnostic = runtimeAdapter.id == .antigravityCLI
            ? AntigravityCLIRuntime.diagnosticSummary(
                logPath: AntigravityCLIRuntime.diagnosticLogPath(task: task, runID: run.id)
            )
            : nil
        var payload = requiredArtifact
            ? "\(providerName) finished with exit code 0 but did not return text output and did not create a usable file for this run. Retry this task or switch providers."
            : "\(providerName) finished with exit code 0 but did not return text output or create a visible file. Retry this task or switch providers."
        if let antigravityDiagnostic {
            payload += " \(antigravityDiagnostic.message) Diagnostic log: \(antigravityDiagnostic.logPath)"
        }
        if let error = result.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            payload += " Provider stderr: \(String(RuntimeReadinessRedactor.redacted(error).prefix(300)))"
        }
        let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run)
        modelContext.insert(event)
        var auditFields = [
            "runtime": runtimeAdapter.id.rawValue,
            "phase": phase,
            "exit_code": String(result.exitCode),
            "run_output_chars": String(run.output.count),
            "file_changes": String(run.fileChanges.count),
            "run_scoped_file_result": String(visibleFileResult),
            "requires_artifact": String(requiredArtifact),
            "stderr_bytes": String(result.error?.utf8.count ?? 0)
        ]
        if let antigravityDiagnostic {
            auditFields.merge(antigravityDiagnostic.auditFields) { _, new in new }
        }
        AppLogger.audit(.runtimeEmptyOutput, category: "Worker", taskID: task.id, fields: auditFields, level: .warning)
        return true
    }

    @MainActor
    private static func applyDeliverableVerificationFailureIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) async -> Bool {
        let result = await TaskDeliverableVerificationService.evaluate(task: task, run: run, modelContext: modelContext)
        guard let eventType = TaskDeliverableVerificationService.eventType(for: result) else {
            return false
        }

        let event = TaskEvent(
            task: task,
            type: eventType,
            payload: TaskDeliverableVerificationService.encode(result),
            run: run
        )
        modelContext.insert(event)

        let auditEvent: AuditEvent = switch result.status {
        case "passed":
            .deliverableVerificationPassed
        case "review_needed":
            .deliverableVerificationReviewNeeded
        default:
            .deliverableVerificationFailed
        }
        AppLogger.audit(auditEvent, category: "Validation", taskID: task.id, fields: [
            "run_id": run.id.uuidString,
            "profile": result.profile.rawValue,
            "level": result.level.rawValue,
            "status": result.status,
            "can_complete": String(result.canComplete),
            "requires_human_review": String(result.requiresHumanReview),
            "check_count": String(result.checks.count),
            "evidence_count": String(result.evidencePaths.count)
        ], level: result.shouldBlockCompletion ? .warning : .info)

        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        guard decision.shouldBlockCompletion else {
            return false
        }

        applyCompletionBlock(decision, task: task, run: run, modelContext: modelContext)
        return true
    }

    @MainActor
    private static func applyAutomaticBaselineVerificationIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) async {
        let result = await TaskInferredValidationService.runAutomaticBaselineIfNeeded(
            task: task,
            modelContext: modelContext
        )
        guard result.didRun else { return }

        AppLogger.audit(
            result.canComplete ? .validationContractPassed : .validationContractFailed,
            category: "Validation",
            taskID: task.id,
            fields: [
                "run_id": run.id.uuidString,
                "source": "automatic_inferred_baseline",
                "can_complete": String(result.canComplete),
                "failed_required_assertion_count": String(result.failedRequiredAssertionIDs.count)
            ],
            level: result.canComplete ? .info : .warning
        )

        let decision = TaskCompletionPolicy.decide(inferredValidation: result)
        guard decision.canComplete else {
            applyCompletionBlock(decision, task: task, run: run, modelContext: modelContext)
            return
        }
    }

    @MainActor
    private static func applyManualCompletion(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        successPayload: String
    ) -> Bool {
        let decision = TaskCompletionPolicy.decideManualCompletion(task: task, run: run)
        if decision.shouldBlockCompletion {
            applyCompletionBlock(decision, task: task, run: run, modelContext: modelContext)
            return false
        }

        task.status = .completed
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.completed, payload: successPayload, run: run)
        modelContext.insert(event)
        return true
    }

    @MainActor
    private static func applyCompletionBlock(
        _ decision: TaskCompletionPolicyDecision,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        run.status = .failed
        run.typedStopReason = decision.typedStopReason ?? TaskRunStopReason.custom(decision.gate.rawValue)
        task.status = .pendingUser
        task.completedAt = nil
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.error,
            payload: decision.userVisibleMessage ?? "Task completion blocked by \(decision.gate.rawValue).",
            run: run
        ))
    }

    @MainActor
    private static func recordEstimatedUsageIfProviderDidNotReport(
        runtimeAdapter: any AgentRuntimeWorkerEventRecording,
        selectedRuntime: AgentRuntimeID,
        prompt: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard runtimeAdapter.recordsEstimatedUsageWhenProviderUsageMissing,
              run.tokensUsed == 0 else {
            return
        }

        let estimatedInput = AgentRuntimeProcessRunner.estimatedLaunchInputTokens(
            prompt: prompt,
            runtime: selectedRuntime
        )
        let estimatedOutput = AgentProcessMonitor.estimatedTokenCount(for: run.output)
        let estimatedTotal = estimatedInput + estimatedOutput
        guard estimatedTotal > 0 else { return }

        run.tokensUsed = estimatedTotal
        run.inputTokens = estimatedInput
        run.outputTokens = estimatedOutput
        task.tokensUsed += estimatedTotal

        let detail = "estimated tokens: \(estimatedTotal) (in: \(estimatedInput), out: \(estimatedOutput)) | provider usage unavailable"
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.stats, payload: detail, run: run))
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "tokens_total": String(estimatedTotal),
            "tokens_input": String(estimatedInput),
            "tokens_output": String(estimatedOutput),
            "runtime": selectedRuntime.rawValue,
            "source": "estimated_provider_usage_missing"
        ])
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

    @MainActor
    private func utilityRuntimeConfiguration(
        for role: TaskRoleID,
        task: AgentTask,
        fallbackRuntime: AgentRuntimeID,
        preferredModel: String,
        modelContext: ModelContext
    ) -> AgentUtilityRuntimeConfiguration {
        let roleRuntime = TaskRoleProfileStore.utilityRuntime(
            for: role,
            task: task,
            defaultRuntimeID: fallbackRuntime.rawValue,
            defaultModel: preferredModel,
            validationModel: preferredModel,
            defaultBudget: task.tokenBudget,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            providerSettings: runtimeConfiguration.configuredProviderSettings
        )
        TaskRoleProfileStore.recordSelected(roleRuntime.selection, task: task, modelContext: modelContext)
        return roleRuntime.configuration
    }

    @MainActor
    private func createChainedTask(
        from task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        let output = run.output
        let nextTask = AgentTask(
            title: String(task.chainedGoal.prefix(60)),
            goal: task.chainedGoal,
            workspace: task.workspace,
            tokenBudget: task.tokenBudget,
            model: task.model,
            runtime: task.resolvedRuntimeID,
            isolationStrategy: task.isolationStrategy,
            validationStrategy: task.validationStrategy
        )
        nextTask.status = .queued
        nextTask.chainedFromID = task.id
        nextTask.runtimeID = task.runtimeID
        // A chained follow-up continues in the same checkout and execution
        // environment as its parent.
        nextTask.executionRootPath = task.executionRootPath
        nextTask.executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        if !output.isEmpty {
            nextTask.inputs = ["Previous task output (\(task.title)):\n\(String(output.prefix(5000)))"]
        }
        nextTask.skills = task.skills
        TaskCapabilitySnapshotter.capture(for: nextTask)
        modelContext.insert(nextTask)

        let chainEvent = TaskEvent(task: task, eventType: TaskEventTypes.Task.chained,
            payload: "Chained to next task: \(nextTask.title)")
        modelContext.insert(chainEvent)
        AppLogger.audit(.taskChained, category: "Worker", taskID: task.id, fields: [
            "next_task_id": nextTask.id.uuidString
        ])
    }

    @MainActor
    private func scheduleGeneratedTitleIfNeeded(
        for task: AgentTask,
        selectedRuntime: AgentRuntimeID,
        modelContext: ModelContext
    ) {
        guard task.runs.count == 1,
              task.title == String(task.goal.prefix(60)),
              let ws = task.workspace else {
            return
        }

        let goalText = task.goal
        let wsPath = ws.primaryPath
        let titleRuntime = utilityRuntimeConfiguration(
            for: .summarizer,
            task: task,
            fallbackRuntime: selectedRuntime,
            preferredModel: validationModel,
            modelContext: modelContext
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
        run.typedStopReason = .policyBlocked
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
    private static let providerLaunchSignatureEventType = "astra.provider_launch_signature"

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

    private struct NativeContinuationDecision {
        let sessionID: String?
        let skipReason: String
        let signatureMatched: Bool
    }

    private struct ProviderLaunchSignaturePayload: Codable, Equatable {
        let version: Int
        let runtimeID: String
        let model: String
        let policyLevel: String
        var policyScope: String
        let providerAdapterVersion: Int
        let permissionMode: String
        var allowedTools: [String]
        var askFirstTools: [String]
        var deniedTools: [String]
        let allowedShellPatterns: [String]
        let askFirstShellPatterns: [String]
        let deniedShellPatterns: [String]
        let allowedURLPatterns: [String]
        let deniedURLPatterns: [String]
        let runtimeSupportTools: [String]
        let scopedSkillIDs: [String]
        let scopedSkillNames: [String]
        let scopedConnectorDescriptors: [String]
        let scopedLocalToolCommands: [String]
        let environmentKeyNames: [String]
        let credentialLabels: [String]
        let mcpServerIDs: [String]
        let browserAdapters: [String]
        let promptSchemaVersion: String
        let executionEnvironmentFingerprint: String?

        var signatureValue: String {
            [
                "v=\(version)",
                "runtime=\(runtimeID)",
                "model=\(model)",
                "policyLevel=\(policyLevel)",
                "policyScope=\(policyScope)",
                "adapter=\(providerAdapterVersion)",
                "permission=\(permissionMode)",
                "allowed=\(allowedTools.joined(separator: ","))",
                "ask=\(askFirstTools.joined(separator: ","))",
                "denied=\(deniedTools.joined(separator: ","))",
                "allowShell=\(allowedShellPatterns.joined(separator: ","))",
                "askShell=\(askFirstShellPatterns.joined(separator: ","))",
                "denyShell=\(deniedShellPatterns.joined(separator: ","))",
                "allowURL=\(allowedURLPatterns.joined(separator: ","))",
                "denyURL=\(deniedURLPatterns.joined(separator: ","))",
                "support=\(runtimeSupportTools.joined(separator: ","))",
                "skillIDs=\(scopedSkillIDs.joined(separator: ","))",
                "skillNames=\(scopedSkillNames.joined(separator: ","))",
                "connectors=\(scopedConnectorDescriptors.joined(separator: ","))",
                "tools=\(scopedLocalToolCommands.joined(separator: ","))",
                "env=\(environmentKeyNames.joined(separator: ","))",
                "credentials=\(credentialLabels.joined(separator: ","))",
                "mcp=\(mcpServerIDs.joined(separator: ","))",
                "browserAdapters=\(browserAdapters.joined(separator: ","))",
                "prompt=\(promptSchemaVersion)",
                "environment=\(executionEnvironmentFingerprint ?? WorkspaceExecutionEnvironment.host.signatureFingerprint)"
            ].joined(separator: "\u{1f}")
        }
    }

    // Approval grants accumulate inside a task, so signatures are compared
    // modulo grant-derived entries: otherwise the first post-approval turn
    // always reads as a policy change and drops the provider session.
    private static func grantNeutralizedSignatureValue(
        _ payload: ProviderLaunchSignaturePayload,
        grantStrings: Set<String>
    ) -> String {
        guard !grantStrings.isEmpty else { return payload.signatureValue }
        let grantKeys = Set(grantStrings.map(canonicalToolKey))
        var neutral = payload
        neutral.allowedTools = payload.allowedTools.filter { !grantStrings.contains($0) }
        neutral.askFirstTools = payload.askFirstTools.filter { !grantKeys.contains(canonicalToolKey($0)) }
        neutral.deniedTools = payload.deniedTools.filter { !grantKeys.contains(canonicalToolKey($0)) }
        neutral.policyScope = "grant_neutral"
        return neutral.signatureValue
    }

    private static func canonicalToolKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func signatureGrantStrings(for manifest: RunPermissionManifest) -> Set<String> {
        guard !manifest.approvalGrants.isEmpty else { return [] }
        return Set(
            PermissionBroker.providerGrantStrings(for: manifest.approvalGrants, runtime: manifest.providerID)
                + PermissionBroker.providerRuntimeGrantStrings(for: manifest.approvalGrants, runtime: manifest.providerID)
        )
    }

    @MainActor
    private static func nativeContinuationSessionID(
        for task: AgentTask,
        currentRun: TaskRun,
        runtimeAdapter: any AgentRuntimeDescriptorReadiness,
        phase: String,
        currentLaunchSignature: ProviderLaunchSignaturePayload,
        grantNeutralizingStrings: Set<String> = []
    ) -> NativeContinuationDecision {
        guard phase == "resume",
              runtimeAdapter.descriptor.supportsNativeContinuation else {
            return NativeContinuationDecision(sessionID: nil, skipReason: "unsupported_or_not_resume_phase", signatureMatched: false)
        }

        guard let sessionID = task.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return NativeContinuationDecision(sessionID: nil, skipReason: "missing_session_id", signatureMatched: false)
        }

        if shouldSkipNativeContinuationAfterLastRun(task, currentRun: currentRun) {
            return NativeContinuationDecision(sessionID: nil, skipReason: "unsafe_previous_no_progress_run", signatureMatched: false)
        }

        guard let previousRun = priorRun(forNativeSessionID: sessionID, task: task, currentRun: currentRun) else {
            return NativeContinuationDecision(sessionID: nil, skipReason: "missing_previous_session_run", signatureMatched: false)
        }

        guard let previousSignature = providerLaunchSignature(for: task, run: previousRun) else {
            return NativeContinuationDecision(sessionID: nil, skipReason: "missing_previous_launch_signature", signatureMatched: false)
        }

        let previousValue = grantNeutralizedSignatureValue(previousSignature, grantStrings: grantNeutralizingStrings)
        let currentValue = grantNeutralizedSignatureValue(currentLaunchSignature, grantStrings: grantNeutralizingStrings)
        guard previousValue == currentValue else {
            return NativeContinuationDecision(sessionID: nil, skipReason: "launch_signature_changed", signatureMatched: false)
        }

        return NativeContinuationDecision(sessionID: sessionID, skipReason: "none", signatureMatched: true)
    }

    private static func shouldSkipNativeContinuationAfterLastRun(_ task: AgentTask, currentRun: TaskRun) -> Bool {
        guard let lastRun = task.runs
            .filter({ $0.id != currentRun.id })
            .sorted(by: { $0.startedAt > $1.startedAt })
            .first,
              lastRun.status == .failed,
              lastRun.typedStopReason.map({
                  [.providerNoSemanticProgress, .providerNoActionableProgress].contains($0)
              }) == true,
              lastRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private static func priorRun(forNativeSessionID sessionID: String, task: AgentTask, currentRun: TaskRun) -> TaskRun? {
        task.runs
            .filter { $0.id != currentRun.id }
            .filter { $0.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID }
            .max { $0.startedAt < $1.startedAt }
    }

    @MainActor
    private static func providerLaunchSignature(
        for task: AgentTask,
        manifest: RunPermissionManifest,
        contextText: String
    ) -> ProviderLaunchSignaturePayload {
        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        let supportTools = manifest.providerRender.runtimeSupportTools.map { descriptor in
            [
                descriptor.name,
                descriptor.providerNativePermission ?? "",
                descriptor.allowedInputKeys.joined(separator: "+"),
                descriptor.deniedInputKeys.joined(separator: "+")
            ].joined(separator: ":")
        }
        let connectorDescriptors = scope.connectors.map { connector in
            [
                connector.id.uuidString,
                connector.name,
                connector.serviceType,
                connector.baseURL
            ].joined(separator: ":")
        }
        let localToolCommands = scope.localTools.compactMap { tool -> String? in
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            return command
        }
        return ProviderLaunchSignaturePayload(
            version: 1,
            runtimeID: manifest.providerID.rawValue,
            model: manifest.model,
            policyLevel: manifest.policyLevel.rawValue,
            policyScope: manifest.policyScope.rawValue,
            providerAdapterVersion: manifest.providerRender.adapterVersion,
            permissionMode: manifest.providerRender.permissionMode,
            allowedTools: canonicalStrings(manifest.providerRender.allowedTools),
            askFirstTools: canonicalStrings(manifest.providerRender.askFirstTools),
            deniedTools: canonicalStrings(manifest.providerRender.deniedTools),
            allowedShellPatterns: canonicalStrings(manifest.providerRender.allowedShellPatterns),
            askFirstShellPatterns: canonicalStrings(manifest.providerRender.askFirstShellPatterns),
            deniedShellPatterns: canonicalStrings(manifest.providerRender.deniedShellPatterns),
            allowedURLPatterns: canonicalStrings(manifest.providerRender.allowedURLPatterns),
            deniedURLPatterns: canonicalStrings(manifest.providerRender.deniedURLPatterns),
            runtimeSupportTools: canonicalStrings(supportTools),
            scopedSkillIDs: canonicalStrings(scope.behaviorSkills.map { $0.id.uuidString }),
            scopedSkillNames: canonicalStrings(scope.behaviorSkills.map(\.name)),
            scopedConnectorDescriptors: canonicalStrings(connectorDescriptors),
            scopedLocalToolCommands: canonicalStrings(localToolCommands),
            environmentKeyNames: canonicalStrings(manifest.environmentKeyNames),
            credentialLabels: canonicalStrings(manifest.credentialLabels),
            mcpServerIDs: canonicalStrings(manifest.mcpServers.map { "\($0.packageID):\($0.id)" }),
            browserAdapters: canonicalStrings(scope.enabledBrowserAdapters),
            promptSchemaVersion: "context_capsule_v2",
            executionEnvironmentFingerprint: DockerExecutionPlanner.resolveEnvironment(for: task).signatureFingerprint
        )
    }

    @MainActor
    private static func recordProviderLaunchSignature(
        _ signature: ProviderLaunchSignaturePayload,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard let data = try? JSONEncoder().encode(signature),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        modelContext.insert(TaskEvent(task: task, type: providerLaunchSignatureEventType, payload: payload, run: run))
    }

    private static func providerLaunchSignature(for task: AgentTask, run: TaskRun) -> ProviderLaunchSignaturePayload? {
        task.events
            .filter { $0.type == providerLaunchSignatureEventType && $0.run?.id == run.id }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { event -> ProviderLaunchSignaturePayload? in
                guard let data = event.payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(ProviderLaunchSignaturePayload.self, from: data)
            }
            .last
    }

    private static func canonicalStrings(_ values: [String]) -> [String] {
        Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
    }

    private static func runtimeID(from rawValue: String?) -> AgentRuntimeID? {
        rawValue.flatMap(AgentRuntimeID.init(rawValue:))
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
        var tools = Set(TaskCapabilityResolver(task: task).promptScope().resolver.resolvedProviderAllowedTools)
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
        run.typedStopReason = TaskRunStopReason.custom(reason)
        task.status = Self.isTerminalRuntimeStop(reason) ? .failed : .pendingUser

        let payload = result.runtimeStopMessage
            ?? "ASTRA stopped the provider because browser control reached a terminal guardrail: \(reason)."
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run))
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "phase": phase,
            "reason": reason,
            "source": "runtime_stop"
        ], level: .error)
        return true
    }

    private static func isTerminalRuntimeStop(_ reason: String) -> Bool {
        guard let stopReason = TaskRunStopReason(rawValue: reason) else { return false }
        if stopReason.isDockerRuntimeBlocked {
            return true
        }
        return [
            .providerPermissionDeniedBroadPermissions,
            .providerPermissionUnresumable,
            .providerNoActionableProgress,
            .providerNoSemanticProgress,
            .providerSemanticProgressStalled
        ].contains(stopReason)
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
        run.typedStopReason = .repetitionDetected
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

    @MainActor
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

    var runtimeReadinessService = RuntimeReadinessService()
    /// Maximum execution time in seconds (10 minutes default)
    var timeoutSeconds: TimeInterval = 600

    /// Permission policy applied to CLI runs. Review/restricted is the safe default;
    /// the composer security gate can opt into autonomous runs for trusted work.
    var skipPermissions: Bool = false
    var permissionPolicy: PermissionPolicy = .restricted

    /// Routes provider permission prompts through ASTRA mid-run (stdio control
    /// protocol) for providers that support it, instead of failing the run and
    /// relaunching after approval.
    var liveApprovalsEnabled: Bool = true

}
