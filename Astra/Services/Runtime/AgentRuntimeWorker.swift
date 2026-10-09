import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@Observable
final class AgentRuntimeWorker {
    private(set) var isRunning = false
    private var cancellationRequested = false
    private var runtimeConfiguration = AgentRuntimeConfiguration()
    private let processRunner: any AgentRuntimeProcessRunning
    private let providerSettingsSnapshotProvider: () -> ProviderSettingsSnapshot
    var budgetEnforcementModeOverride: BudgetEnforcementMode?
    var permissionPromotionPersistence: (() throws -> Void)?
    /// Home directory in which provider session stores are looked up before a
    /// native resume. Tests point it at a scratch directory.
    var providerSessionStoreHome = FileManager.default.homeDirectoryForCurrentUser.path

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
    @MainActor init(
        processRunner: any AgentRuntimeProcessRunning = AgentRuntimeProcessRunner(),
        providerSettingsSnapshotProvider: @escaping () -> ProviderSettingsSnapshot = {
            RuntimeSettingsSnapshotStore.providerSnapshot()
        }
    ) {
        self.processRunner = processRunner
        self.providerSettingsSnapshotProvider = providerSettingsSnapshotProvider
        AppLogger.audit(.workerStarted, category: "Worker", fields: [
            "phase": "initialized",
            "default_runtime": defaultRuntimeID.rawValue,
            "provider_path_configured": String(!runtimeConfiguration.executablePath(for: defaultRuntimeID).isEmpty)
        ], level: .debug)
    }

    /// Execute a task with its configured agent runtime.
    @discardableResult
    @MainActor
    func execute(
        task: AgentTask,
        modelContext: ModelContext,
        promptOverride: String? = nil,
        startEventPayload: String? = nil,
        existingStartEventID: UUID? = nil,
        executionRequestID: UUID? = nil,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        approvedPlan: RuntimeTurnSettlementService.ApprovedPlan? = nil,
        retainIsolationAfterExecution: Bool = false,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async -> AgentRuntimeExecutionContext? {
        let launchTask = executionPolicy.launchSnapshot.map { TaskExecutionLaunchSnapshotApplicator.detachedTask($0, from: task) } ?? task
        let selectedRuntime = runtimeConfiguration.selectedRuntime(for: launchTask)
        AgentRuntimeLaunchRuntimeResolver.reconcilePersistedRuntime(
            task: launchTask, selectedRuntime: selectedRuntime, phase: "run")
        alignTaskModelWithSelectedRuntime(launchTask, selectedRuntime: selectedRuntime, phase: "run")
        // Clear on the LIVE task, not the frozen copy: sessionId is durable
        // state (`detachedTask` copies it from source, not from the snapshot),
        // and both consumers read the live task — `TaskRun.init` captures
        // `task.sessionId` into `run.providerSessionId`, and
        // `nativeContinuationSessionID(for: task,)` decides continuation from
        // it. Clearing the detached copy would let a rerouted run inherit the
        // previous runtime's session, which is exactly what the ordering
        // comment below this call site promises cannot happen.
        clearMismatchedProviderSessionIfNeeded(for: task, selectedRuntime: selectedRuntime, phase: "run")
        TaskCapabilitySnapshotter.refreshForFreshRun(task: launchTask)
        var executionContext: AgentRuntimeExecutionContext?
        await executeRuntimeSession(
            task: task,
            launchTask: launchTask,
            modelContext: modelContext,
            selectedRuntime: selectedRuntime,
            onEvent: onEvent,
            promptOverride: promptOverride,
            startEventPayload: startEventPayload,
            existingStartEventID: existingStartEventID,
            turnRequestID: executionRequestID,
            auditPhase: "run",
            recordingMode: .initial,
            executionPolicy: executionPolicy,
            approvedPlan: approvedPlan,
            retainIsolationAfterExecution: retainIsolationAfterExecution,
            onExecutionContext: { executionContext = $0 }
        )
        return executionContext
    }

    @MainActor
    func executeApprovedPlan(
        task: AgentTask,
        plan: TaskPlanPayload,
        mode: TaskPlanExecutionMode = .fullPlan,
        existingStartEventID: UUID? = nil,
        executionRequestID: UUID? = nil,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        let launchTask = executionPolicy.launchSnapshot.map { TaskExecutionLaunchSnapshotApplicator.detachedTask($0, from: task) } ?? task
        let currentPlan = TaskPlanService.reconstruct(for: task).plan ?? plan
        let approvedStep = mode == .nextStep ? TaskPlanService.nextExecutableStep(in: currentPlan) : nil
        if mode == .nextStep, approvedStep == nil {
            guard await ApprovedPlanRuntimeSettlement.validateApprovedPlanContractForFinalCompletion(
                task: task,
                plan: currentPlan,
                modelContext: modelContext,
                verifierRuntime: utilityRuntimeConfiguration(for: .verifier, task: task,
                    fallbackRuntime: runtimeConfiguration.selectedRuntime(for: launchTask),
                    preferredModel: validationModel, modelContext: modelContext)
            ) else {
                WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                return
            }
            TaskPlanService.recordExecutionCompleted(planID: currentPlan.planID, task: task, modelContext: modelContext)
            TaskStateMachine.completeFromRuntime(task, modelContext: modelContext)
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
            // The task was admitted to `.running` before this preflight (see
            // TaskQueue approved-plan admission). Without a terminal transition
            // here the queue removes the worker and the task is stranded Running
            // forever with no way to retry from the UI. Fail it so it becomes
            // actionable again, mirroring the completion path above.
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            return
        }

        TaskPlanService.recordExecutionStarted(planID: currentPlan.planID, task: task, modelContext: modelContext)
        let selectedRuntime = runtimeConfiguration.selectedRuntime(for: launchTask)
        AgentRuntimeLaunchRuntimeResolver.reconcilePersistedRuntime(
            task: launchTask, selectedRuntime: selectedRuntime, phase: "run")
        let planPrompt = if let approvedStep {
            AgentPromptBuilder.buildApprovedPlanStepExecutionPrompt(for: launchTask, plan: currentPlan, step: approvedStep)
        } else {
            AgentPromptBuilder.buildApprovedPlanExecutionPrompt(for: launchTask, plan: currentPlan)
        }
        let prompt = planPrompt + TaskPermissionContinuation.approvedPlanResumeGuidance(
            executionRequestID: executionRequestID, task: task, modelContext: modelContext)
        let runExecutionPolicy = Self.approvedPlanExecutionPolicy(
            runtime: selectedRuntime,
            currentPermissionPolicy: permissionPolicy,
            task: launchTask,
            plan: currentPlan,
            step: approvedStep
        )
        .addingRuntimePermissions(from: executionPolicy)
        .withLaunchSnapshot(executionPolicy.launchSnapshot)
        .withTurnIntentSnapshot(executionPolicy.turnIntentSnapshot)
        .withResourceAdmission(from: executionPolicy)
        let executionContext = await execute(
            task: task, modelContext: modelContext, promptOverride: prompt,
            startEventPayload: approvedStep.map { "Agent started approved plan step: \($0.title)" }
                ?? "Agent started executing approved plan: \(currentPlan.title)",
            existingStartEventID: existingStartEventID, executionRequestID: executionRequestID,
            executionPolicy: runExecutionPolicy,
            approvedPlan: .init(plan: currentPlan, step: approvedStep),
            retainIsolationAfterExecution: true, onEvent: onEvent)
        executionContext?.cleanup()
    }

    /// Continue an existing session with a follow-up message (HITL flow).
    @MainActor
    func continueSession(
        task: AgentTask,
        message: String, existingMessageEventID: UUID? = nil, turnRequestID: UUID? = nil,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async {
        let launchTask = executionPolicy.launchSnapshot.map { TaskExecutionLaunchSnapshotApplicator.detachedTask($0, from: task) } ?? task
        let selectedRuntime = runtimeConfiguration.selectedRuntime(for: launchTask)
        AgentRuntimeLaunchRuntimeResolver.reconcilePersistedRuntime(
            task: launchTask,
            selectedRuntime: selectedRuntime,
            phase: "resume"
        )
        alignTaskModelWithSelectedRuntime(launchTask, selectedRuntime: selectedRuntime, phase: "resume")
        // Live task — see the note at the "run" phase call site.
        clearMismatchedProviderSessionIfNeeded(for: task, selectedRuntime: selectedRuntime, phase: "resume")
        await executeRuntimeSession(
            task: task,
            launchTask: launchTask,
            modelContext: modelContext,
            selectedRuntime: selectedRuntime,
            onEvent: onEvent,
            startEventType: "user.message",
            startEventPayload: message,
            existingStartEventID: existingMessageEventID,
            turnRequestID: turnRequestID,
            sessionMessage: message,
            auditPhase: "resume",
            recordingMode: .followUp,
            executionPolicy: executionPolicy
        )
    }
    @MainActor
    private func executeRuntimeSession(
        task: AgentTask,
        launchTask: AgentTask,
        modelContext: ModelContext,
        selectedRuntime: AgentRuntimeID,
        onEvent: @escaping (ParsedEvent) -> Void,
        promptOverride: String? = nil,
        startEventType: String = "task.started",
        startEventPayload: String? = nil, existingStartEventID: UUID? = nil, turnRequestID: UUID? = nil,
        sessionMessage: String? = nil,
        auditPhase: RunPhase = .run,
        recordingMode: AgentRuntimeRecordingMode = .initial,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        approvedPlan: RuntimeTurnSettlementService.ApprovedPlan? = nil,
        retainIsolationAfterExecution: Bool = false,
        onExecutionContext: ((AgentRuntimeExecutionContext) -> Void)? = nil
    ) async {
        var executionPolicy = executionPolicy.turnIntentSnapshot == nil
            ? executionPolicy.withTurnIntentSnapshot(TaskTurnIntentResolver.capture(
                for: launchTask,
                sourceEventID: existingStartEventID,
                acceptedTurn: sessionMessage ?? startEventPayload ?? launchTask.goal,
                includeTaskInputs: auditPhase == .run
            ))
            : executionPolicy
        var selectedRuntime = selectedRuntime
        var runtimeAdapter = AgentRuntimeAdapterRegistry.adapter(for: selectedRuntime)
        var launchSettings = runtimeAdapter.launchSettings(configuration: runtimeConfiguration)
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "status": task.status.rawValue,
            "model": launchTask.model,
            "runtime": selectedRuntime.rawValue,
            "phase": auditPhase.rawValue,
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])
        if auditPhase == .resume {
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
        guard AgentRuntimeStartAdmission.confirmRuntimeSessionStarted(
            task: task,
            modelContext: modelContext,
            auditPhase: auditPhase
        ) else {
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
        defer { isRunning = false }
        cancellationRequested = false

        // Settle executionEnvironmentSnapshotJSON before resolving
        // requirements, not the whole TaskRun: the resolver's own
        // DockerExecutionPlanner.resolveEnvironment fallback disagrees with
        // TaskRun.init's for historical tasks with no snapshot yet, so
        // resolving first risked stale requirements. An earlier version of
        // this fix constructed TaskRun itself early, which fixed that but
        // broke two other things that depend on TaskRun NOT existing yet at
        // this point: clearMismatchedProviderSessionIfNeeded's "latest run"
        // lookup (task.runs would include the new, not-yet-started run) and
        // run.providerSessionId (would capture task.sessionId before a
        // reroute clears it). Settling just the field TaskRun.init would
        // otherwise settle avoids both.
        if launchTask.executionEnvironmentSnapshotJSON == nil {
            launchTask.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(
                ExecutionEnvironmentStore.decode(launchTask.workspace?.activeExecutionEnvironmentJSON)
            )
        }

        await CodexMCPPolicyService.warmBeforeLaunch(configuration: runtimeConfiguration)
        let runtimeResolution = AgentRuntimeLaunchRuntimeResolver.resolve(
            task: launchTask,
            requestedRuntime: selectedRuntime,
            runtimeConfiguration: runtimeConfiguration,
            promptOverride: promptOverride,
            startEventPayload: startEventPayload,
            sessionMessage: sessionMessage,
            phase: auditPhase,
            executionPolicy: executionPolicy,
            fallbackPermissionPolicy: skipPermissions ? .autonomous : permissionPolicy,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            isHostControlBrokerAvailable: {
                processRunner.isHostControlBrokerAvailable()
            }
        )
        // Before the reroute is applied: a launch the gate stops must not
        // rewrite the task's runtime toward the provider it refused.
        let sensitiveDataBlock = RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: runtimeResolution.requestedRuntime, launchRuntime: runtimeResolution.runtime)
        let appliedRuntime = AgentRuntimeLaunchRuntimeResolver.apply(
            sensitiveDataBlock == nil ? runtimeResolution : runtimeResolution.withoutReroute,
            task: launchTask,
            phase: auditPhase,
            alignModel: { runtime in
                alignTaskModelWithSelectedRuntime(launchTask, selectedRuntime: runtime, phase: auditPhase)
            },
            clearMismatchedSession: { runtime in
                // Live task — see the note at the "run" phase call site.
                clearMismatchedProviderSessionIfNeeded(for: task, selectedRuntime: runtime, phase: auditPhase)
            }
        )
        if appliedRuntime.reroutedFrom != nil {
            selectedRuntime = appliedRuntime.runtime
            runtimeAdapter = AgentRuntimeAdapterRegistry.adapter(for: selectedRuntime)
            launchSettings = runtimeAdapter.launchSettings(configuration: runtimeConfiguration)
        }
        // Resolved from the binary this run will actually exec, then carried on
        // the policy so the prompt describes the same routes the launch
        // attaches. After the reroute, so it names the runtime that won rather
        // than the one that was asked for.
        let runtimeCapabilityProfile = AgentRuntimeCapabilityProfileService.profile(
            for: selectedRuntime,
            executablePath: launchSettings.executablePath
        )
        executionPolicy = executionPolicy.withRuntimeCapabilityProfile(runtimeCapabilityProfile)

        let run = TaskRun(task: task)
        run.runtimeID = selectedRuntime.rawValue
        // A new attempt does not yet own the task's previous provider session.
        run.providerSessionId = nil
        modelContext.insert(run)
        // Link the event to its run BEFORE the running-state save below, so
        // the same save durably persists both facts together. No later save
        // in this launch path is guaranteed to run before the provider
        // starts (e.g. a clean-workspace git baseline capture skips its own
        // save) — if the link were set only in memory here, a crash before
        // any later save would leave the durable user message permanently
        // detached from the run that answered it.
        let startPayload = startEventPayload ?? runtimeAdapter.defaultStartEventPayload(task: launchTask)
        PersistedTurnRuntimeEventLinker.link(eventID: existingStartEventID, to: run, for: task, fallbackType: startEventType, fallbackPayload: startPayload, in: modelContext)
        let turnBegin = PersistedTurnRuntimeEventLinker.beginRuntime(requestID: turnRequestID, run: run, task: task, in: modelContext)
        var settlementHandled = false
        defer {
            if !settlementHandled {
                PersistedTurnRuntimeEventLinker.finishRuntime(request: turnBegin.request, run: run,
                    task: task, in: modelContext)
            }
        }
        // Unpersisted running state = provider-boundary abort (run already failed by beginRuntime).
        guard turnBegin.persisted else { return }
        executionPolicy.followsUpDeliveredRequest = TaskDeliverableExpectation.followsUpDeliveredRequest(run, in: task)
        let executionWorkspaceAccess = executionPolicy.workspaceAccessOverride
            ?? TaskExecutionResourceClaimResolver.workspaceAccess(for: turnBegin.request)
        AgentRuntimeLaunchRuntimeResolver.insertRerouteEventIfNeeded(
            appliedRuntime,
            task: task,
            run: run,
            modelContext: modelContext
        )

        let providerLaunchContextText = runtimeAdapter.connectorPreflightContextText(
            task: launchTask,
            promptOverride: promptOverride,
            startPayload: startPayload,
            sessionMessage: sessionMessage,
            phase: auditPhase
        )
        let launchPermissionPolicy = effectivePermissionPolicy(
            for: launchTask,
            selectedRuntime: selectedRuntime,
            executionPolicy: executionPolicy
        )
        let admittedCapabilitySnapshot = appliedRuntime.capabilityResolutionSnapshot
        if let sensitiveDataBlock {
            RuntimeSensitiveDataLaunchGate.record(sensitiveDataBlock, task: task, run: run, modelContext: modelContext, phase: auditPhase)
            isRunning = false
            return
        }
        if let block = appliedRuntime.launchBlock {
            AgentRuntimeCapabilityBlockRecorder.apply(
                block,
                runtime: selectedRuntime,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: auditPhase,
                selectedRuntimeEvidence: appliedRuntime.selectedRuntimeEvidence
            )
            return
        }

        guard AgentRuntimeLaunchPreflight.preflightExecutableBeforeLaunch(
            task: task, run: run, adapter: runtimeAdapter,
            executablePath: launchSettings.executablePath,
            runtime: selectedRuntime.rawValue, modelContext: modelContext
        ) else {
            return
        }

        guard await AgentRuntimeLaunchPreflight.preflightRuntimeReadinessBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            configuration: runtimeReadinessConfiguration(for: selectedRuntime),
            readinessService: runtimeReadinessService,
            verdictCache: launchReadinessCache
        ) else {
            return
        }

        let capabilityPreflightCache = PreflightCache(checker: environmentHealthChecker)
        let capabilityWorkingDirectory = TaskWorkspaceAccess(task: launchTask).codeWorkingDirectory
        guard await AgentRuntimeConnectorPreflight.passed(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            contextText: providerLaunchContextText,
            permissionPolicy: launchPermissionPolicy,
            executionPolicy: executionPolicy,
            capabilityResolutionSnapshot: admittedCapabilitySnapshot,
            precomputedRuntimeRequirements: appliedRuntime.requirements,
            runtimeConfiguration: runtimeConfiguration,
            preflightCache: capabilityPreflightCache,
            capabilityWorkingDirectory: capabilityWorkingDirectory,
            mcpDetectExecutable: mcpServerExecutableDetector,
            mcpIsExecutableFile: mcpServerExecutableIsResolvable,
            testingOverride: connectorPreflightTestingOverride
        ) else {
            return
        }
        // The connector gate may have just recorded a task grant: Auto allows a
        // connector without asking. The admitted snapshot predates it, so the
        // exposure is refreshed from the durable grants before anything is built
        // from it, or this launch would start without what the chat says was
        // allowed.
        let capabilityResolutionSnapshot = admittedCapabilitySnapshot.addingApprovedCredentialLabels(
            TaskRuntimePermissionGrants.approvedCredentialLabels(
                for: task,
                runtime: selectedRuntime,
                additionalGrants: executionPolicy.permissionGrantsOverride ?? []
            )
        )
        let githubRepositoryStatus = await capabilityPreflightCache.cachedStatus(
            for: CommonCLIPrerequisites.githubAuth,
            workingDirectory: capabilityWorkingDirectory
        )

        _ = AgentRuntimeLaunchPreflight.preflightRemoteWorkspaceBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            runtime: selectedRuntime
        )

        let codeDir = TaskWorkspaceAccess(task: launchTask).codeWorkingDirectory
        if TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(
            request: turnBegin.request,
            task: launchTask
        ) {
            let claimedPath = turnBegin.request?.resourceClaims.first {
                $0.kind == .workspace
            }?.key ?? "unknown"
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "reason": "execution_request_workspace_drift",
                "claimed_path": claimedPath,
                "live_path": codeDir
            ], level: .error)
            run.status = .failed
            run.completedAt = Date()
            run.typedStopReason = TaskRunStopReason.custom("execution_request_workspace_drift")
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: run.completedAt ?? Date())
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "The task workspace changed after this run was submitted. Start a new run so ASTRA can acquire the correct workspace lock.",
                run: run
            ))
            return
        }
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
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: run.completedAt ?? Date())
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                payload: "Workspace directory not found: \(codeDir)", run: run)
            modelContext.insert(event)
            return
        }

        guard await AgentRuntimeLaunchPreflight.preflightDockerImageBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase
        ) else {
            return
        }

        guard AgentRuntimeLaunchPreflight.preflightCredentialProjectionBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            codeDirectory: codeDir
        ) else {
            return
        }

        let executionPath: String
        let shouldCleanupIsolation: Bool
        if runtimeAdapter.shouldPrepareIsolation(phase: auditPhase) {
            do {
                executionPath = try await IsolationService.prepare(task: launchTask)
                shouldCleanupIsolation = true
                if executionPath != TaskWorkspaceAccess(task: launchTask).effectiveWorkspacePath {
                    let isoEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use,
                        payload: "Isolation: \(launchTask.isolationStrategy.rawValue) -> \(executionPath)", run: run)
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
                TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: run.completedAt ?? Date())
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                    payload: "Workspace isolation failed: \(error.localizedDescription)", run: run)
                modelContext.insert(event)
                return
            }
        } else {
            executionPath = codeDir
            shouldCleanupIsolation = false
        }
        let executionContext = AgentRuntimeExecutionContext.make(
            launchTask: launchTask,
            executionPath: executionPath,
            shouldCleanupIsolation: shouldCleanupIsolation
        )
        let executionTask = executionContext.task
        onExecutionContext?(executionContext)
        defer {
            if !retainIsolationAfterExecution {
                executionContext.cleanup()
            }
        }

        let approvedSandboxPaths = TaskLaunchResourceResolver.approvedSandboxReadablePaths(
            from: executionPolicy.permissionGrantsOverride ?? [],
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path)
        let runEnvironment = AgentRuntimeRunEnvironmentContext.prepare(
            task: executionTask, currentDirectory: executionPath, providerLaunchContextText: providerLaunchContextText,
            workspaceAccess: executionWorkspaceAccess,
            approvedSandboxReadablePaths: approvedSandboxPaths)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(runEnvironment.runSnapshot)
        let basePrompt = (auditPhase == .resume && approvedPlan == nil
            ? AgentPromptBuilder.buildFreshFollowUpPrompt(message: sessionMessage ?? startPayload,
                task: executionTask, executionPolicy: executionPolicy)
            : promptOverride) ?? buildPrompt(
            for: executionTask,
            executionPolicy: executionPolicy,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot
        )
        let policyPrompt = AskGitPullRequestWorkflowPolicy.appendingProviderGuidance(
            to: basePrompt,
            task: executionTask,
            permissionPolicy: launchPermissionPolicy,
            contextText: providerLaunchContextText
        )
        let readinessPrompt = GitHubCapabilityLaunchContext.appendingProviderGuidance(
            to: HostControlPlanePromptGuidance.appendingAutoSendGuidance(
                to: policyPrompt,
                permissionPolicy: launchPermissionPolicy
            ),
            repositoryStatus: githubRepositoryStatus
        )
        var prompt = runEnvironment.appendingReadOnlyInputGuidance(to: readinessPrompt)
        let launchResourcePlan = TaskLaunchResourceResolver.resolve(
            task: executionTask,
            runID: run.id,
            runtime: selectedRuntime,
            phase: auditPhase,
            prompt: prompt,
            contextText: providerLaunchContextText,
            workspacePath: executionPath,
            executionEnvironment: runEnvironment.runSnapshot,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            runtimePermissionGrants: executionPolicy.permissionGrantsOverride ?? [],
            permissionPolicy: launchPermissionPolicy,
            workspaceAccess: executionWorkspaceAccess,
            admittedWritableGitMetadataRoots: TaskExecutionResourceClaimResolver
                .admittedWritableGitMetadataRoots(for: turnBegin.request, task: launchTask),
            // appliedRuntime.requirements is already resolved above (~line 528),
            // so no reordering was needed here — closes the last spot that
            // independently re-derived GitHub host-control routing instead of
            // reusing the resolver's single precomputed answer.
            precomputedRuntimeRequirements: appliedRuntime.requirements,
            runtimeCapabilityProfile: executionPolicy.runtimeCapabilityProfile
        )
        TaskLaunchResourceManifestStore.persist(launchResourcePlan, task: task)
        let budgetEnforcementMode = currentBudgetEnforcementMode
        AgentRuntimeCapabilityLaunchAudit.logResolution(
            for: task,
            runtime: selectedRuntime,
            phase: auditPhase,
            contextText: providerLaunchContextText,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot
        )
        await AgentRuntimeCapabilityLaunchAudit.logGitHubCLIPreflightIfNeeded(
            for: task,
            runtime: selectedRuntime,
            phase: auditPhase,
            contextText: providerLaunchContextText,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            repositoryStatus: githubRepositoryStatus
        )
        let policyRenderer = AgentRuntimeAdapterRegistry.policyRenderer(for: selectedRuntime)
        let providerCapabilities = policyRenderer.policyCapabilities(executablePath: launchSettings.executablePath)
        let runPermissionPolicy = launchPermissionPolicy
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: selectedRuntime,
            model: executionTask.model,
            workspacePath: executionPath,
            phase: auditPhase,
            permissionPolicy: runPermissionPolicy,
            executionPolicy: executionPolicy,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            providerCapabilities: providerCapabilities,
            runtimeCapabilityProfile: runtimeCapabilityProfile,
            contextText: providerLaunchContextText,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            launchResourcePlan: launchResourcePlan,
            precomputedRuntimeRequirements: appliedRuntime.requirements,
            modelContext: modelContext
        )
        guard shouldStartProvider(with: manifest, task: task, run: run, modelContext: modelContext, phase: auditPhase) else {
            return
        }
        let launchSignature = ProviderLaunchSignatureService.make(
            for: task,
            manifest: manifest,
            contextText: providerLaunchContextText,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot, launchResourcePlan: launchResourcePlan
        )
        // OpenCode, Antigravity and Cursor keep their stores under HOME (OpenCode also XDG_DATA_HOME / OPENCODE_DB), which an attached skill may redirect for the launch.
        let baseLaunchEnvironment = ProcessInfo.processInfo.environment.merging(["HOME": providerSessionStoreHome]) { _, home in home }
        let providerLaunchEnvironment = [.openCodeCLI, .antigravityCLI, .cursorCLI].contains(selectedRuntime)
            ? baseLaunchEnvironment.merging(AgentRuntimeProcessRunner.scopedEnvironmentVariables(
                for: executionTask,
                capabilityScope: capabilityResolutionSnapshot.providerLaunch,
                contextText: providerLaunchContextText,
                executionPolicy: executionPolicy,
                runtimeRequirements: appliedRuntime.requirements
            )) { _, scoped in scoped }
            : baseLaunchEnvironment
        let nativeContinuationDecision = Self.nativeContinuationSessionID(
            for: task,
            currentRun: run,
            runtimeAdapter: runtimeAdapter,
            phase: auditPhase,
            currentLaunchSignature: launchSignature,
            grantNeutralizingStrings: ProviderLaunchSignatureService.grantStrings(for: manifest),
            providerHomeDirectory: launchSettings.homeDirectory,
            userHome: providerSessionStoreHome,
            environment: providerLaunchEnvironment
        )
        let nativeContinuationSessionID = nativeContinuationDecision.sessionID
        // What a launch without the resume sends, kept in case a resumed turn comes back empty.
        let historyGuidance = runtimeCapabilityProfile.canDeliverHostControlPlane
            && appliedRuntime.requirements.offeredHostControlTools.contains("history")
            ? TaskHistoryRetrievalGuidance.prompt : ""
        let promptWithoutResume = prompt + historyGuidance
        // Compact only after this launch has proved native continuation safe.
        // Fresh handoffs (including changed signatures) keep the wider context.
        if auditPhase == .resume, approvedPlan == nil, nativeContinuationSessionID != nil {
            prompt = AgentContinuationPrompt.build(message: sessionMessage ?? startPayload,
                task: executionTask, executionPolicy: executionPolicy,
                permissionPolicy: launchPermissionPolicy, contextText: providerLaunchContextText,
                repositoryStatus: githubRepositoryStatus, runEnvironment: runEnvironment)
        }
        prompt += historyGuidance
        logContextPromptDiagnostics(for: task, prompt: prompt, phase: auditPhase)
        guard AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: prompt,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: auditPhase,
            runtime: selectedRuntime,
            budgetEnforcementMode: budgetEnforcementMode
        ) else {
            return
        }
        if auditPhase == .resume {
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
        guard let publicationBeforeGitStatus = TaskGitPublicationWorkspaceBaselineService.capture(
            task: task,
            run: run,
            workspacePath: executionPath,
            modelContext: modelContext
        ) else {
            return
        }
        let beforeGitStatus = runtimeAdapter.recordsInferredFileChanges
            ? publicationBeforeGitStatus
            : nil
        let beforeDirtyFingerprints = beforeGitStatus.map {
            AgentFileChangeDetector.fileFingerprints(
                for: AgentFileChangeDetector.absolutePaths(fromGitStatus: $0, workspacePath: executionPath),
                workspacePath: executionPath
            )
        }
        let taskFolderBeforeRun = await TaskFolderRunSnapshot.capture(for: task)
        await TaskFolderRunSnapshot.persistBaseline(taskFolderBeforeRun, task: task, run: run)
        let capabilityScope = capabilityResolutionSnapshot.providerLaunch
        if !capabilityScope.behaviorSkills.isEmpty {
            let skillNames = capabilityScope.behaviorSkills.map(\.name).joined(separator: ", ")
            let skillEvent = TaskEvent(task: task, eventType: TaskEventTypes.System.skillActive,
                payload: "Active skills: \(skillNames)", run: run)
            modelContext.insert(skillEvent)
        }

        HostControlBrokerSessionRegistry.shared.bindHistory(container: modelContext.container, taskID: task.id, runID: run.id)
        defer { HostControlBrokerSessionRegistry.shared.unbindHistory(taskID: task.id, runID: run.id) }
        let pendingEvents = OrderedMainActorTaskQueue()
        let eventPipeline = AgentRuntimeEventPipelineBox(
            supportsAstraRunProtocol: runtimeAdapter.descriptor.supportsAstraRunProtocol
        )
        let recordingState = AgentEventRecordingState()
        let streamTelemetry = runtimeAdapter.recordsStreamTelemetry ? AgentRuntimeStreamTelemetry() : nil
        let streamDebugCapture = AgentRuntimeStreamDebugCapture.makeIfEnabled()
        let semanticProgressTimeout = AgentRuntimeProgressTimeoutPolicy.semanticProgressTimeout(
            task: executionTask,
            phase: auditPhase,
            idleTimeoutSeconds: timeoutSeconds,
            followsUpDeliveredRequest: executionPolicy.followsUpDeliveredRequest
        )
        // Record only admitted attempts, paired with the session this launch uses.
        // Fresh launches acquire their session ID from the provider's start event.
        run.providerSessionId = nativeContinuationSessionID
        ProviderLaunchSignatureService.record(launchSignature, task: task, run: run, modelContext: modelContext)
        let discardedUsage = DiscardedAttemptUsage()
        let sessionUsageBaseline = nativeContinuationSessionID == nil ? .zero
            : ProviderSessionUsageEpoch.baseline(for: run, in: task)
        let persistRecordedEvent: (AgentRuntimeRecordedEvent) -> Void = { event in
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
        let handleLine: (String, Bool) -> Void = { line, parsesJSONLines in
            PerformanceSignposts.processStreamLine {
                streamTelemetry?.recordRawLine(parsesJSONLines: parsesJSONLines)
                streamDebugCapture?.recordLine(line, parsesJSONLines: parsesJSONLines)
                let parsedBatch = PerformanceSignposts.parseProviderStream {
                    runtimeAdapter.parseWorkerStreamEvents(line: line, parsesJSONLines: parsesJSONLines)
                }
                parsedBatch.recordParsed(to: streamTelemetry)
                parsedBatch.recordParsed(to: streamDebugCapture, rawLine: line)
                let emittedEvents = discardedUsage.apply(to: parsedBatch.events.flatMap {
                    runtimeAdapter.processWorkerStreamEvent($0, pipeline: eventPipeline)
                })
                let emittedBatch = AgentRuntimeStreamEventBatch(events: emittedEvents)
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
        // A resumed turn on a runtime that sometimes answers with reasoning only is held
        // until it shows real output, so an empty one can be re-run without the resume.
        let emptyTurnGate = nativeContinuationSessionID != nil && runtimeAdapter.descriptor.retriesEmptyResumedTurnWithoutResume
            ? NativeResumeEmptyTurnGate(isSubstantiveLine: { line, parsesJSONLines in
                runtimeAdapter.parseWorkerStreamEvents(line: line, parsesJSONLines: parsesJSONLines)
                    .agentEvents.contains(where: NativeResumeEmptyTurnGate.isSubstantive)
            })
            : nil
        let launchTimeoutSeconds = timeoutSeconds
        let launchLiveApprovalsEnabled = liveApprovalsEnabled
        let launchMaxRunSeconds = maxRunSeconds
        let launchProcess: (String, String?, NativeResumeEmptyTurnGate?, TimeInterval, Int, Int) async -> AgentProcessResult = { launchPrompt, nativeSessionID, gate, launchMaxRun, priorTurns, priorTokens in
            var attemptPolicy = launchExecutionPolicy
            attemptPolicy.providerTurnsAlreadyUsed = priorTurns
            attemptPolicy.providerTokensAlreadyUsed = priorTokens
            attemptPolicy.providerSessionUsageBaseline = sessionUsageBaseline
            return await self.processRunner.runRuntimeProcess(
            adapter: runtimeAdapter,
            prompt: launchPrompt,
            task: executionTask,
            workspacePath: executionPath,
            executablePath: launchSettings.executablePath,
            homeDirectory: launchSettings.homeDirectory,
            permissionPolicy: runPermissionPolicy,
            executionPolicy: attemptPolicy,
            permissionManifest: manifest,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: launchTimeoutSeconds,
            phase: auditPhase,
            contextText: providerLaunchContextText,
            nativeContinuationSessionID: nativeSessionID,
            runID: run.id,
            launchResourcePlan: launchResourcePlan,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            runtimeRequirements: appliedRuntime.requirements,
            liveApprovalsEnabled: launchLiveApprovalsEnabled,
            noSemanticProgressTimeoutSeconds: semanticProgressTimeout,
            maxRunSeconds: launchMaxRun,
            onInteractiveAsk: Self.interactiveAskHandler(
                runtime: selectedRuntime, task: task, run: run,
                permissionPolicy: runPermissionPolicy, manifest: manifest,
                modelContext: modelContext, pendingEvents: pendingEvents
            ),
            onLine: { line, parsesJSONLines in
                guard let gate else { return handleLine(line, parsesJSONLines) }
                gate.accept(line, parsesJSONLines, forward: handleLine)
            }
            )
        }
        let firstAttemptStartedAt = Date()
        var result = await launchProcess(prompt, nativeContinuationSessionID, emptyTurnGate, launchMaxRunSeconds, 0, 0)
        if let emptyTurnGate {
            if emptyTurnGate.producedNothing, result.exitCode == 0, !result.stoppedByASTRA, !cancellationRequested {
                // The resumed turn ended cleanly with reasoning only. Re-run it once without the resume.
                AppLogger.audit(.taskResumed, category: "Worker", taskID: task.id, fields: [
                    "continuation_retry": "empty_resumed_turn",
                    "runtime": selectedRuntime.rawValue,
                    "native_session_prefix": nativeContinuationSessionID.map { String($0.prefix(8)) } ?? "none",
                    "prompt_chars": String(promptWithoutResume.count)
                ], level: .warning)
                // The attempt's output is not shown, but what it cost still counts against the run.
                discardedUsage.record(from: emptyTurnGate.discard().flatMap {
                    runtimeAdapter.parseWorkerStreamEvents(line: $0.text, parsesJSONLines: $0.parsesJSONLines).agentEvents
                })
                // The abandoned session must not stay the task's resumable one, however this re-run ends
                // (a hard budget stop below, a failure before its init frame); a successful init replaces it.
                run.providerSessionId = nil
                task.sessionId = nil
                // The full-history prompt is larger than the compact one that was budget-checked.
                guard AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
                    prompt: promptWithoutResume,
                    task: task,
                    run: run,
                    modelContext: modelContext,
                    phase: auditPhase,
                    runtime: selectedRuntime,
                    budgetEnforcementMode: budgetEnforcementMode,
                    alreadyUsedTokens: discardedUsage.totalTokens
                ) else {
                    // The run ends here, but the discarded attempt still spent what it spent.
                    for event in discardedUsage.unappliedEvents() { persistRecordedEvent(event) }
                    await pendingEvents.drainAll()
                    return
                }
                prompt = promptWithoutResume
                // maxRunSeconds bounds the whole run, so the re-run only gets what the first attempt left.
                let remainingRunSeconds = max(1, launchMaxRunSeconds - Date().timeIntervalSince(firstAttemptStartedAt))
                // The empty attempt spent one provider turn of the run's maxTurns.
                result = await launchProcess(prompt, nil, nil, remainingRunSeconds, 1, discardedUsage.totalTokens)
            } else {
                emptyTurnGate.flush(forward: handleLine)
            }
        }
        let flushedBatch = runtimeAdapter.flushWorkerStreamEvents(pipeline: eventPipeline)
        flushedBatch.recordEmitted(to: streamTelemetry)
        flushedBatch.recordEmitted(to: streamDebugCapture)
        for event in flushedBatch.events + discardedUsage.unappliedEvents() {
            persistRecordedEvent(event)
        }
        await pendingEvents.drainAll()
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: recordingState,
            task: task,
            run: run,
            modelContext: modelContext,
            processExitedCleanly: result.exitCode == 0 && !result.stoppedByASTRA && !cancellationRequested
        )
        AssistantMessageRecording.recordMessageIndex(for: run, task: task, modelContext: modelContext, recordingState: recordingState)
        runtimeAdapter.recordPostProcessEvents(context: AgentRuntimePostProcessContext(
            homeDirectory: launchSettings.homeDirectory,
            task: task,
            run: run,
            runStartedAt: startTime,
            modelContext: modelContext,
            recordingState: recordingState,
            recordingMode: recordingMode,
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
        let taskFolderRecord = await TaskFolderRunSnapshot.recordChanges(
            since: taskFolderBeforeRun,
            task: task,
            run: run,
            runStartedAt: startTime,
            executionPath: executionPath
        )
        run.completedAt = Date()
        run.exitCode = result.exitCode
        run.providerVersion = result.providerVersion
        ReadOnlyBoundaryEvidenceRecorder.record(result.readOnlyBoundaryEvidence, task: task, run: run, in: modelContext)
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
                phase: auditPhase.rawValue,
                exitCode: result.exitCode
            )
        }
        let processSucceeded = result.exitCode == 0 || result.terminatedAfterTerminalProgress
        let failureDiagnostic = (processSucceeded || result.runtimeStopped || result.repetitionKilled) ? nil : AgentRuntimeFailureDiagnostic.classify(
            runtime: selectedRuntime,
            model: task.model,
            exitCode: result.exitCode,
            rawError: result.error,
            runOutput: [run.output, result.providerFailureOutput]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
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
                fields: failureDiagnostic.auditFields(phase: auditPhase.rawValue, stream: streamSnapshot),
                level: .error
            )
        }
        AppLogger.audit(.workerExited, category: "Worker", taskID: task.id, fields: [
            "exit_code": String(result.exitCode),
            "runtime": selectedRuntime.rawValue,
            "phase": auditPhase.rawValue,
            "terminated_after_terminal_progress": String(result.terminatedAfterTerminalProgress)
        ], level: processSucceeded ? .info : .warning)

        let resultCheckpoint = RuntimeTurnSettlementService.Checkpoint(
            requestID: turnBegin.request?.id, result: result, runtime: selectedRuntime,
                phase: auditPhase, executionPath: executionPath, launchSnapshot: .init(task: executionTask),
                permissionPolicy: launchPermissionPolicy, sandboxEnforcement: executionPolicy.sandboxEnforcementSnapshot,
                verifierRuntime: utilityRuntimeConfiguration(for: .verifier, task: task,
                    fallbackRuntime: selectedRuntime, preferredModel: validationModel, modelContext: modelContext),
                timeoutSeconds: timeoutSeconds, budgetEnforcementMode: budgetEnforcementMode.rawValue,
                effectiveTokenBudget: AgentRuntimeProcessRunner.effectiveTokenBudget(for: executionTask),
                tokensUsed: task.tokensUsed, agentReportedError: recordingState.agentReportedError(for: run),
                cancelled: cancellationRequested, failureDiagnostic: failureDiagnostic,
                approvedPlan: approvedPlan, chainedGoal: task.chainedGoal, scheduleID: task.originScheduleID,
                sessionMessage: runtimeAdapter.sessionTurnMessage(task: task, promptOverride: promptOverride,
                    startPayload: startEventPayload, sessionMessage: sessionMessage, phase: auditPhase),
                autoSendsAtSettlement: true)

        // Before the outcome branches, not inside one. What the run left behind
        // for the user is waiting whether the run succeeded, was cancelled, or
        // failed right after leaving it; only a clean finish lets Auto allow a
        // connector the run reached for.
        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: task,
            run: run,
            modelContext: modelContext,
            policyLevel: manifest.policyLevel,
            runFinishedCleanly: RuntimeTurnSettlementService.finishedCleanly(
                checkpoint: resultCheckpoint, taskStatus: task.status)
        )

        do {
            try RuntimeTurnSettlementService.capture(resultCheckpoint, task: task, run: run, modelContext: modelContext)
        } catch {
            RuntimeTurnSettlementService.reportPersistenceFailure(task: task, run: run, modelContext: modelContext)
            settlementHandled = true
            return
        }
        settlementHandled = true
        guard let checkpoint = try? RuntimeTurnSettlementService.checkpoint(for: run, task: task) else {
            RuntimeTurnSettlementService.reportPersistenceFailure(task: task, run: run, modelContext: modelContext)
            return
        }
        guard await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: task, run: run,
            modelContext: modelContext, permissionPromotionPersistence: permissionPromotionPersistence,
            connectorMutationCoordinator: connectorMutationCoordinatorFactory?(modelContext)) else { return }

        RuntimeTurnSettlementService.dispatchChainedTask(task: task, run: run, modelContext: modelContext)
        if runtimeAdapter.performsPostRunFollowUps(phase: auditPhase) {
            scheduleGeneratedTitleIfNeeded(for: task, selectedRuntime: selectedRuntime, modelContext: modelContext)
        }
        await TaskFolderRunSnapshot.settleBaseline(taskFolderRecord, task: task, run: run)
    }
    nonisolated static func durableFailureStopReason(category: AgentRuntimeFailureCategory?) -> TaskRunStopReason {
        guard let category,
              category != .providerProcessFailed,
              let reason = TaskRunStopReason.custom(category.rawValue) else { return .failed }
        return reason
    }
    @MainActor
    func cancel() {
        cancellationRequested = true
        processRunner.cancel()
    }
    // MARK: - Private

    private func runtimeReadinessConfiguration(for runtime: AgentRuntimeID) -> RuntimeReadinessConfiguration {
        let providerSnapshot = providerSettingsSnapshotProvider()
        return RuntimeReadinessConfiguration(
            runtime: runtime,
            providerSettings: runtimeConfiguration.configuredProviderSettings,
            claudeProvider: providerSnapshot.claudeProvider,
            vertexProjectID: providerSnapshot.vertexProjectID,
            vertexRegion: providerSnapshot.vertexRegion,
            vertexOpusModel: providerSnapshot.vertexOpusModel,
            vertexSonnetModel: providerSnapshot.vertexSonnetModel,
            vertexHaikuModel: providerSnapshot.vertexHaikuModel,
            antigravityAuthMode: providerSnapshot.antigravityAuthMode
        )
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
    private func logContextPromptDiagnostics(for task: AgentTask, prompt: String, phase: RunPhase) {
        AppLogger.audit(
            .contextPromptDiagnostics,
            category: "Worker",
            taskID: task.id,
            fields: TaskContextStateManager.promptDiagnosticsFields(
                task: task,
                prompt: prompt,
                phase: phase.rawValue
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

    @MainActor
    private func shouldStartProvider(
        with manifest: RunPermissionManifest,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) -> Bool {
        let blockedDiagnostics = manifest.providerRender.diagnostics.filter { $0.severity == .blocked }
        guard !blockedDiagnostics.isEmpty else { return true }

        run.status = .failed
        run.completedAt = Date()
        run.typedStopReason = .policyBlocked
        TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext, at: run.completedAt ?? Date())

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
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.System.runtimeLaunchBlocked,
            payload: TaskRunLaunchBlockPayload.forPolicyDiagnostics(blockedDiagnostics),
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
            "phase": phase.rawValue,
            "blocked_diagnostics": String(blockedDiagnostics.count),
            "policy_level": manifest.policyLevel.rawValue,
            "runtime": manifest.providerID.rawValue
        ], level: .warning)
        isRunning = false
        return false
    }

    typealias ProcessResult = AgentProcessResult
    typealias ProcessMonitor = AgentProcessMonitor

    static let compactionThreshold = AgentEventCompactor.threshold
    static let compactionKeepCount = AgentEventCompactor.keepCount

    @MainActor
    private func alignTaskModelWithSelectedRuntime(
        _ task: AgentTask,
        selectedRuntime: AgentRuntimeID,
        phase: RunPhase
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
        phase: RunPhase
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
            "phase": phase.rawValue,
            "history_run_count": String(task.runs.count)
        ], level: .info)
    }

    private struct NativeContinuationDecision {
        let sessionID: String?
        let skipReason: String
        let signatureMatched: Bool
    }

    @MainActor
    private static func nativeContinuationSessionID(
        for task: AgentTask,
        currentRun: TaskRun,
        runtimeAdapter: any AgentRuntimeDescriptorReadiness,
        phase: RunPhase,
        currentLaunchSignature: ProviderLaunchSignaturePayload,
        grantNeutralizingStrings: Set<String> = [],
        providerHomeDirectory: String = "",
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NativeContinuationDecision {
        guard phase == .resume,
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

        let storeLookup = ProviderNativeSessionStore.lookup(
            runtime: runtimeAdapter.descriptor.id,
            sessionID: sessionID,
            providerHomeDirectory: providerHomeDirectory,
            userHome: userHome,
            environment: environment
        )
        guard storeLookup == .present else {
            // Only a confirmed absence stops the task advertising the session; a store that could not be
            // read says nothing about it, so the session stays for a later attempt.
            if storeLookup == .absent { task.sessionId = nil }
            return NativeContinuationDecision(
                sessionID: nil,
                skipReason: storeLookup == .absent ? "provider_session_missing" : "provider_session_unverifiable",
                signatureMatched: false
            )
        }

        guard let previousSignature = ProviderLaunchSignatureService.storedSignature(for: task, run: previousRun) else {
            return NativeContinuationDecision(sessionID: nil, skipReason: "missing_previous_launch_signature", signatureMatched: false)
        }

        let previousValue = ProviderLaunchSignatureService.grantNeutralizedValue(
            previousSignature,
            grantStrings: grantNeutralizingStrings
        )
        let currentValue = ProviderLaunchSignatureService.grantNeutralizedValue(
            currentLaunchSignature,
            grantStrings: grantNeutralizingStrings
        )
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
        // This resolves capabilities independently of the shared
        // `TaskCapabilityResolutionSnapshot` captured later in
        // `executeRuntimeSession`, and that is intentional, not a redundant
        // fifth resolution to fold into the snapshot: the allowed-tools set here
        // feeds the approved-plan `AgentRuntimeExecutionPolicy`, which is an
        // INPUT to `execute()` — but `execute()` runs
        // `TaskCapabilitySnapshotter.refreshForFreshRun` and only then captures
        // the authoritative launch snapshot. Reusing a snapshot taken at this
        // point would predate that refresh (and it's plan-scoped, layering the
        // approved step's likely tools on top). The launch snapshot remains the
        // enforcement authority; this is the pre-refresh planning view.
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

    /// Whether a runtime stop is final or the run should wait for the user.
    ///
    /// Internal rather than private so a test can pin the membership directly:
    /// the failure mode this list guards against — a deterministic stop parked
    /// in `pendingUser`, waiting on an approval that changes nothing — is
    /// invisible from the outside until someone notices a run that never moves.
    static func isTerminalRuntimeStop(_ reason: String) -> Bool {
        guard let stopReason = TaskRunStopReason(rawValue: reason) else { return false }
        if stopReason.isDockerRuntimeBlocked {
            return true
        }
        return [
            .providerPermissionDeniedBroadPermissions,
            .providerPermissionUnresumable,
            .providerNoActionableProgress,
            .providerNoSemanticProgress,
            .providerSemanticProgressStalled,
            .providerActiveToolStalled,
            .providerWorkspaceJobStalled,
            .providerRunWallClockExceeded
        ].contains(stopReason)
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
    func buildPrompt(
        for task: AgentTask,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil
    ) -> String {
        AgentPromptBuilder.buildPrompt(
            for: task,
            executionPolicy: executionPolicy,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot
        )
    }

    @MainActor
    func effectivePermissionPolicy(
        for task: AgentTask,
        selectedRuntime: AgentRuntimeID,
        executionPolicy: AgentRuntimeExecutionPolicy
    ) -> PermissionPolicy {
        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: AgentPolicyLevel.normalized(defaultAgentPolicyLevelRaw),
            fallbackPermissionPolicy: skipPermissions ? .autonomous : permissionPolicy,
            executionPolicy: executionPolicy
        )
        return ProviderPolicyModeResolver.permissionPolicy(
            for: resolution.policy,
            runtime: selectedRuntime
        )
    }

    /// Model used for AI validation checks
    var validationModel: String = "claude-haiku-4-5-20251001"

    var runtimeReadinessService = RuntimeReadinessService()
    /// Remembers a recent fully-ready launch verdict. Nil unless production
    /// composition opts in (`AppRuntimeController`), so tests never share one.
    var launchReadinessCache: RuntimeLaunchReadinessCache?
    /// Backs the capability-prerequisite preflight (e.g. `gh auth status`
    /// for the GitHub capability). A fresh `PreflightCache` is constructed
    /// from this per launch (see the call site below) so a retry after the
    /// user fixes a CLI/auth issue always re-probes instead of replaying a
    /// stale cached failure. Scenario tests swap this for a checker wired
    /// to `InstantSuccessBinaryRunner` so the check never shells out to
    /// real host CLIs.
    var environmentHealthChecker = EnvironmentHealthChecker()
#if DEBUG
    var connectorPreflightOverrideForTesting: (() async -> Bool)?
#endif
    /// Whether an MCP stdio server's resolved command path is executable
    /// (e.g. ~/.astra/tools/astra-host-control for the GitHub host-control
    /// server). Scenario tests override this so the capability preflight
    /// never depends on ASTRA's bundled tools being installed on the
    /// machine running the test.
    var mcpServerExecutableIsResolvable: (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }
    /// Resolves a bare MCP server command name via PATH, mirroring
    /// `RuntimePathResolver.detectExecutablePath` in production.
    var mcpServerExecutableDetector: (String) -> String = {
        RuntimePathResolver.detectExecutablePath(named: $0)
    }
    /// Maximum execution time in seconds (10 minutes default)
    var timeoutSeconds: TimeInterval = 600
    /// Wall-clock ceiling on one provider run, net of managed-job time.
    var maxRunSeconds: TimeInterval = RuntimeProgressSignals.defaultMaxRunSeconds

    /// Permission policy applied to CLI runs. Review/restricted is the safe default;
    /// the composer security gate can opt into autonomous runs for trusted work.
    var skipPermissions: Bool = false
    var permissionPolicy: PermissionPolicy = .restricted

    /// Routes provider permission prompts through ASTRA mid-run (stdio control
    /// protocol) for providers that support it, instead of failing the run and
    /// relaunching after approval.
    var liveApprovalsEnabled: Bool = true

    /// Builds the coordinator an Auto run's staged connector writes are sent
    /// through during settlement. Nil uses the real sender; tests inject one
    /// so they can prove what would have gone out without reaching a network.
    var connectorMutationCoordinatorFactory: (@MainActor (ModelContext) -> ConnectorMutationCoordinator)?

}
