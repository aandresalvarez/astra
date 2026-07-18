import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@Observable @MainActor
final class TaskLifecycleCoordinator {
    let modelContext: ModelContext
    let taskQueue: TaskQueue

    init(modelContext: ModelContext, taskQueue: TaskQueue) {
        self.modelContext = modelContext
        self.taskQueue = taskQueue
    }

    /// Canonical follow-up message sent when the user resumes a previously
    /// session-backed task. The task-specific variant appends ASTRA's resolved
    /// active objective so stale original goals do not re-anchor long threads.
    static let resumeContinuationMessage = "Continue where you left off. Continue the current objective."

    static func resumeContinuationMessage(for task: AgentTask) -> String {
        let objective = TaskContextStateManager.activeObjectiveText(for: task)
        guard !objective.isEmpty else { return resumeContinuationMessage }
        let base = resumeContinuationMessage.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\(base): \(boundedResumeObjective(objective))"
    }

    // MARK: - Task Lifecycle

    func runQueue() {
        if taskQueue.isProcessing {
            taskQueue.cancelAll()
            let summary = TaskRunLifecycleService.cancelAllRunningTasks(modelContext: modelContext)
            AppLogger.audit(.taskCancelled, category: "UI", fields: [
                "source": "queue_toggle",
                "running_runs_cancelled": String(summary.runsUpdated),
                "tasks_cancelled": String(summary.tasksUpdated)
            ])
            return
        }
        Task {
            await taskQueue.processQueue(modelContext: modelContext)
            // B2-live: resume any Workspace App workflow run whose awaited agent
            // task just finished in the queue.
            await WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: modelContext)
        }
    }

    /// Returns the continuation `Task` so callers (notably tests) can await the
    /// run to fully drain before tearing down the model container. The handle is
    /// `@discardableResult` — production callers ignore it and behaviour is
    /// unchanged.
    @discardableResult
    func runSingleTask(_ task: AgentTask) -> Task<Void, Never> {
        AppLogger.audit(.taskStarted, category: "UI", taskID: task.id, fields: [
            "source": "manual_run"
        ])
        return Task {
            await taskQueue.executeTask(task, modelContext: modelContext)
            AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                "status": task.status.rawValue
            ])
            // B2-live: resume any Workspace App workflow awaiting this agent task.
            await WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: modelContext)
        }
    }

    func cancelTask(_ task: AgentTask) {
        taskQueue.cancel(task: task, modelContext: modelContext)
        let summary = TaskRunLifecycleService.cancelTask(
            task,
            modelContext: modelContext,
            source: .userAction
        )
        AppLogger.audit(.taskCancelled, category: "UI", taskID: task.id, fields: [
            "source": "user_action",
            "running_runs_cancelled": String(summary.runsUpdated),
            "events_inserted": String(summary.eventsInserted)
        ])
        TaskRunLifecycleService.persist(summary: summary, modelContext: modelContext)
    }

    /// Returns the continuation `Task` (the follow-up run, or the delegated
    /// `runSingleTask` handle) so callers can await the run to fully drain.
    /// `@discardableResult` — production callers ignore it.
    @discardableResult
    func retryTask(_ task: AgentTask) -> Task<Void, Never>? {
        let retryTurn = latestRetryableTurnRequest(for: task)
        let retryFollowUpMessage = retryTurn.flatMap { message(for: $0, task: task) }
            ?? Self.latestRetryableFollowUpMessage(for: task)
        let retryMode = retryTurn != nil
            ? "durable_follow_up"
            : (retryFollowUpMessage == nil ? "initial_task" : "latest_follow_up")
        AppLogger.audit(.taskRetried, category: "UI", taskID: task.id, fields: [
            "retry_mode": retryMode
        ])
        let interruptionSummary = TaskRunLifecycleService.cancelTask(
            task,
            modelContext: modelContext,
            source: .supersededByNewRun
        )
        TaskStateMachine.enqueueFromRetry(task, modelContext: modelContext)
        task.tokensUsed = 0
        task.costUSD = 0
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.retried,
            payload: retryFollowUpMessage == nil
                ? "Task re-queued for retry."
                : "Latest follow-up re-queued for retry."
        )
        modelContext.insert(event)
        if interruptionSummary.runsUpdated > 0 {
            AppLogger.audit(.taskInterrupted, category: "UI", taskID: task.id, fields: [
                "source": TaskRunInterruptionSource.supersededByNewRun.auditSource,
                "running_runs_cancelled": String(interruptionSummary.runsUpdated),
                "next_status": task.status.rawValue
            ], level: .warning)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        if let retryTurn, let retryFollowUpMessage {
            _ = TaskTurnRequestStateMachine.transition(retryTurn, to: .waitingForWorker)
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: [
                    "operation": "retry_turn_request",
                    "request_id": retryTurn.id.uuidString
                ]
            )
            AppLogger.audit(.taskStarted, category: "UI", taskID: task.id, fields: [
                "source": "retry_durable_follow_up",
                "request_id": retryTurn.id.uuidString
            ])
            return Task {
                let didStart = await taskQueue.continueSession(
                    task: task,
                    message: retryFollowUpMessage,
                    existingMessageEventID: retryTurn.messageEventID,
                    turnRequestID: retryTurn.id,
                    modelContext: modelContext
                )
                guard didStart else { return }
                AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                    "status": task.status.rawValue,
                    "source": "retry_durable_follow_up"
                ])
            }
        } else if let retryFollowUpMessage {
            AppLogger.audit(.taskStarted, category: "UI", taskID: task.id, fields: [
                "source": "retry_latest_follow_up"
            ])
            return Task {
                let didStart = await taskQueue.continueSession(
                    task: task,
                    message: retryFollowUpMessage,
                    modelContext: modelContext
                )
                guard didStart else { return }
                AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                    "status": task.status.rawValue,
                    "source": "retry_latest_follow_up"
                ])
            }
        } else {
            return runSingleTask(task)
        }
    }

    private func latestRetryableTurnRequest(for task: AgentTask) -> TaskTurnRequest? {
        guard let requests = try? TaskTurnRequestRepository.requests(for: task, in: modelContext) else {
            return nil
        }
        return requests
            .filter { $0.state == .failed || $0.state == .cancelled }
            .last
    }

    private func message(for request: TaskTurnRequest, task: AgentTask) -> String? {
        task.events.first(where: { $0.id == request.messageEventID })?.payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func resumeTask(_ task: AgentTask) -> Task<Void, Never>? {
        guard task.hasProviderSession else {
            AppLogger.audit(.workerSessionCleared, category: "UI", taskID: task.id, fields: [
                "reason": "missing_session_id"
            ], level: .warning)
            return nil
        }
        AppLogger.audit(.taskResumed, category: "UI", taskID: task.id)
        task.updatedAt = Date()
        task.markRead()
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.resumed, payload: "Resuming previous session — continuing where the agent left off.")
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        return Task {
            let didStart = await taskQueue.continueSession(
                task: task,
                message: Self.resumeContinuationMessage(for: task),
                modelContext: modelContext
            )
            guard didStart else { return }
            AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                "status": task.status.rawValue,
                "source": "resume"
            ])
        }
    }

    @discardableResult
    func approveTask(_ task: AgentTask) -> Task<Void, Never>? {
        if task.status == .pendingUser,
           hasOpenRuntimePermissionApprovalRequest(task) {
            return approveRuntimePermissionAndContinue(task)
        }

        if let latestRun = dismissibleLatestRun(for: task) {
            dismissWithoutMarkingCompleted(task, latestRun: latestRun)
            return nil
        }

        if let latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt }),
           TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task,
            run: latestRun
           ) != nil {
            let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
                task: task,
                run: latestRun
            )
            if decision.shouldBlockCompletion {
                TaskRuntimeOutcomeTransition.applyCompletionBlock(
                    decision,
                    task: task,
                    run: latestRun,
                    modelContext: modelContext
                )
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: task.workspace,
                    modelContext: modelContext
                )
                return nil
            }
        }

        let recordedValidationOverride = recordValidationOverrideIfNeeded(for: task)
        AppLogger.audit(.taskApproved, category: "UI", taskID: task.id, fields: [
            "approval_type": recordedValidationOverride ? "validation_override" : "completion"
        ])
        TaskStateMachine.completeFromUserApproval(task, modelContext: modelContext)
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.approved,
            payload: recordedValidationOverride
                ? "Task approved by user despite a failed required validation contract."
                : "Task approved by user."
        )
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        return nil
    }

    private func recordValidationOverrideIfNeeded(for task: AgentTask) -> Bool {
        guard let failedContract = latestFailedValidationContract(for: task) else { return false }
        let payload = TaskValidationContractEventPayload(
            version: 1,
            planID: failedContract.planID,
            status: "overridden",
            requiredPassed: failedContract.requiredPassed,
            requiredTotal: failedContract.requiredTotal,
            failedRequiredAssertionIDs: failedContract.failedRequiredAssertionIDs,
            summary: "User closed the task despite failed required validation assertions."
        )
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Validation.contractOverridden,
            payload: Self.encode(payload)
        ))
        return true
    }

    private func latestFailedValidationContract(for task: AgentTask) -> TaskValidationContractEventPayload? {
        let currentPlanID = TaskPlanService.reconstruct(for: task).plan?.planID
        let contractEvents = task.events.compactMap { event -> (event: TaskEvent, payload: TaskValidationContractEventPayload)? in
            guard [TaskValidationEventTypes.contractPassed,
                   TaskValidationEventTypes.contractFailed,
                   TaskValidationEventTypes.contractOverridden].contains(event.type),
                  let payload = Self.decodeContractPayload(event.payload),
                  currentPlanID.map({ $0 == payload.planID }) ?? true else {
                return nil
            }
            return (event, payload)
        }
        guard let latest = contractEvents.sorted(by: { $0.event.timestamp > $1.event.timestamp }).first,
              latest.event.type == TaskValidationEventTypes.contractFailed else {
            return nil
        }
        return latest.payload
    }

    private func dismissibleLatestRun(for task: AgentTask) -> TaskRun? {
        guard task.status == .pendingUser else { return nil }
        guard !hasOpenRuntimePermissionApprovalRequest(task) else { return nil }

        let latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt })
        guard PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: latestRun) != nil else {
            return nil
        }
        return latestRun
    }

    private func dismissWithoutMarkingCompleted(_ task: AgentTask, latestRun: TaskRun) {
        AppLogger.audit(.taskApproved, category: "UI", taskID: task.id, fields: [
            "approval_type": "dismiss_without_completion"
        ])
        task.isDone = true
        task.updatedAt = Date()
        task.completedAt = nil
        task.markRead()
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.dismissed,
            payload: "Task dismissed by user without marking it completed.",
            run: latestRun
        )
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    @discardableResult
    func approveSimilarRuntimePermissionForTask(_ task: AgentTask) -> Task<Void, Never>? {
        guard task.status == .pendingUser,
              hasOpenRuntimePermissionApprovalRequest(task) else {
            return approveTask(task)
        }

        let runtime = task.resolvedRuntimeID
        let latestGrants = Self.latestRuntimePermissionGrants(for: task)
        let latestRequestedTool = Self.latestRequestedPermissionTool(for: task)
        let taskScopedGrants = TaskRuntimePermissionGrants.record(
            grants: latestGrants,
            providerID: runtime,
            task: task,
            modelContext: modelContext,
            source: "approve_similar"
        )
        guard !taskScopedGrants.isEmpty else {
            return approveRuntimePermissionAndContinue(task)
        }

        AppLogger.audit(.taskApproved, category: "UI", taskID: task.id, fields: [
            "approval_type": "runtime_permission",
            "approval_scope": "task",
            "runtime": runtime.rawValue,
            "grant_count": String(taskScopedGrants.count)
        ])
        TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: task)
        task.updatedAt = Date()
        task.markRead()
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.approved,
            payload: "Runtime permission approved by user for similar requests in this task. Continuing with task-scoped provider permissions."
        )
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)

        // A live in-flight ask means the provider process is still alive and
        // blocked on this decision: answer it over the control channel instead
        // of relaunching a new run. The recorded grants cover later turns.
        if InFlightPermissionCenter.shared.resolveAll(taskID: task.id, approved: true) > 0 {
            return Task {}
        }

        let resumeMessage = PermissionBroker.resumeMessage(
            providerID: runtime,
            grants: taskScopedGrants,
            fallback: latestRequestedTool
                .flatMap { PermissionBroker.permissionGrant(fromProviderString: $0)?.displayName },
            scopeDescription: "task-scoped runtime permission for similar requests in this task"
        )
        return Task {
            let didStart = await taskQueue.continueSession(
                task: task,
                message: resumeMessage,
                modelContext: modelContext,
                executionPolicy: .default
            )
            guard didStart else { return }
            AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                "status": task.status.rawValue,
                "source": "runtime_permission_task_approval"
            ])
        }
    }

    private func approveRuntimePermissionAndContinue(_ task: AgentTask) -> Task<Void, Never> {
        let runtime = task.resolvedRuntimeID
        let approvedGrants = Self.approvedRuntimePermissionGrants(for: task)
        let resumeMessage = Self.runtimePermissionApprovalResumeMessage(for: task, grants: approvedGrants)
        AppLogger.audit(.taskApproved, category: "UI", taskID: task.id, fields: [
            "approval_type": "runtime_permission",
            "runtime": runtime.rawValue
        ])
        TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: task)
        task.updatedAt = Date()
        task.markRead()
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.approved,
            payload: "Runtime permission approved by user. Continuing with one-time expanded provider permissions."
        )
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)

        // Live in-flight ask: answer the waiting provider process instead of
        // relaunching a new run.
        if InFlightPermissionCenter.shared.resolveAll(taskID: task.id, approved: true) > 0 {
            AppLogger.audit(.taskApproved, category: "UI", taskID: task.id, fields: [
                "approval_type": "runtime_permission_live",
                "approval_scope": "once"
            ])
            return Task {}
        }

        let executionPolicy = PermissionBroker.executionPolicy(forRuntime: runtime, grants: approvedGrants)
        return Task {
            let didStart = await taskQueue.continueSession(
                task: task,
                message: resumeMessage,
                modelContext: modelContext,
                executionPolicy: executionPolicy
            )
            guard didStart else { return }
            AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                "status": task.status.rawValue,
                "source": "runtime_permission_approval"
            ])
        }
    }

    private static func runtimePermissionApprovalResumeMessage(
        for task: AgentTask,
        grants: [PermissionGrant]
    ) -> String {
        var message = PermissionBroker.resumeMessage(
            providerID: task.resolvedRuntimeID,
            grants: grants,
            fallback: latestRequestedPermissionTool(for: task)
                .flatMap { PermissionBroker.permissionGrant(fromProviderString: $0)?.displayName }
        )
        if let blockedRequest = latestBlockedUserRequest(for: task) {
            message += """


            Original blocked user request: \(blockedRequest)

            Continue by answering that request now. Do not answer an earlier turn or the approval notice itself.
            """
        }
        return message
    }

    private static func approvedRuntimePermissionGrants(for task: AgentTask) -> [PermissionGrant] {
        TaskRuntimePermissionOpenRequestStore.latestApprovalGrants(for: task)
    }

    private static func latestRuntimePermissionGrants(for task: AgentTask) -> [PermissionGrant] {
        TaskRuntimePermissionOpenRequestStore.latestApprovalGrants(for: task)
    }

    private static func latestRequestedPermissionTool(for task: AgentTask) -> String? {
        TaskRuntimePermissionOpenRequestStore.latestRequestedToolName(for: task)
    }

    private static func permissionRequestEvents(for task: AgentTask) -> [TaskEvent] {
        task.events
            .filter { $0.type == "permission.denied" || $0.type == "permission.approval.requested" }
    }

    private static func latestBlockedUserRequest(for task: AgentTask) -> String? {
        let latestPermissionEvent = permissionRequestEvents(for: task)
            .sorted { $0.timestamp < $1.timestamp }
            .last
        let cutoff = latestPermissionEvent?.timestamp ?? Date.distantFuture
        let request = latestActionableUserMessage(for: task, before: cutoff)
        let fallback = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return request ?? (fallback.isEmpty ? nil : fallback)
    }

    private static func latestRetryableFollowUpMessage(for task: AgentTask) -> String? {
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message = latestActionableUserMessage(for: task) else { return nil }
        return message == goal ? nil : message
    }

    private static func latestActionableUserMessage(
        for task: AgentTask,
        before cutoff: Date = Date.distantFuture
    ) -> String? {
        task.events
            .filter { $0.type == "user.message" }
            .filter { $0.timestamp <= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
            .reversed()
            .compactMap { event -> String? in
                let trimmed = event.payload.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !isRuntimePermissionResumePrompt(trimmed) else { return nil }
                return trimmed
            }
            .first
    }

    private static func isRuntimePermissionResumePrompt(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("astra approved one-time runtime permission") ||
            normalized.hasPrefix("astra approved task-scoped runtime permission")
    }

    private func hasOpenRuntimePermissionApprovalRequest(_ task: AgentTask) -> Bool {
        TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task)
    }

    func deleteTask(_ task: AgentTask) -> Workspace? {
        AppLogger.audit(.taskDeleted, category: "UI", taskID: task.id)
        let workspace = task.workspace
        modelContext.delete(task)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        return workspace
    }

    func setDoneState(_ task: AgentTask, to isDone: Bool) {
        task.isDone = isDone
        task.updatedAt = Date()
        task.markRead()
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "apply_done_state"]
        )
    }

    func activeSameThreadSchedules(for task: AgentTask) -> [TaskSchedule] {
        task.workspace?.schedules
            .filter { $0.isEnabled && $0.resultMode == .sameThread && $0.sourceTaskID == task.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
    }

    func pauseSchedules(_ schedules: [TaskSchedule]) {
        for schedule in schedules {
            schedule.isEnabled = false
            schedule.updatedAt = Date()
        }
    }

    // MARK: - Workspace Lifecycle

    func createWorkspace(name: String, rootPath: String) -> Workspace {
        let workspaceName = Workspace.displayName(name: name, primaryPath: rootPath)
        let folderName = workspaceName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        let folderPath = (rootPath as NSString).appendingPathComponent(folderName)

        do {
            try PathValidator.validate(folderPath)
            try FileManager.default.createDirectory(
                atPath: folderPath, withIntermediateDirectories: true)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "UI", fields: [
                "operation": "create_workspace_folder",
                "path": folderPath,
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        let ws = Workspace(name: workspaceName, primaryPath: folderPath)
        modelContext.insert(ws)
        seedSkills(for: ws)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: ws, modelContext: modelContext)
        return ws
    }

    func deleteWorkspace(_ ws: Workspace, existingWorkspaces: [Workspace]) -> Workspace? {
        removeGeneratedWorkspaceMirrors(for: ws.primaryPath)

        for connector in ws.connectors {
            connector.cleanupKeychain()
        }
        for skill in ws.skills {
            skill.cleanupKeychain()
            for connector in skill.connectors {
                connector.cleanupKeychain()
            }
        }
        modelContext.delete(ws)

        let next = existingWorkspaces.first(where: { $0.id != ws.id })
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: next, modelContext: modelContext)
        return next
    }

    private func removeGeneratedWorkspaceMirrors(for workspacePath: String) {
        let mirrorPaths = Set([
            WorkspaceFileLayout.workspaceConfigFile(for: workspacePath),
            WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspacePath)
        ])
        for path in mirrorPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func importFromConfig(at url: URL, existingWorkspaces: [Workspace],
                          askDuplicateAction: (String, Int) -> DuplicateAction) -> Workspace? {
        do {
            var config = try WorkspaceConfigManager.loadConfig(from: url)
            config.primaryPath = WorkspaceFileLayout.workspaceRoot(forConfigFile: url).path
            let configID = config.id
            if let existing = existingWorkspaces.first(where: { workspace in
                (configID != nil && workspace.id.uuidString == configID) || workspace.primaryPath == config.primaryPath
            }) {
                let action = askDuplicateAction(config.name, existing.tasks.count)
                switch action {
                case .skip:
                    return nil
                case .replace:
                    if (config.tasks ?? []).isEmpty && !existing.tasks.isEmpty {
                        if let freshExport = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext) {
                            config.tasks = freshExport.tasks
                        }
                    }
                    let scheduleTrustPolicy = scheduleTrustPolicyForConfigReplace(existing: existing, configURL: url)
                    modelContext.delete(existing)
                    return WorkspaceConfigManager.importWorkspace(
                        from: config,
                        modelContext: modelContext,
                        scheduleTrustPolicy: scheduleTrustPolicy
                    )
                case .duplicate:
                    var dupConfig = config
                    dupConfig.name = config.name + " (Imported)"
                    // A duplicate is a new, independent workspace, not the
                    // existing one — clear the carried-over id (importWorkspace
                    // reuses config.id for the new Workspace's id when present)
                    // so it doesn't collide with `existing`'s id. Reusing it
                    // made replaceWorkspaceAppMirrorRows(for: workspace.id...)
                    // delete and re-tag `existing`'s own Workspace App rows.
                    dupConfig.id = nil
                    // Same reasoning, one level down: the exported
                    // WorkspaceApp/Run/RunEvent/DependencyBinding/AutomationState
                    // rows still carry their original appID/runID, which would
                    // let e.g. WorkspaceAppService.deleteApp on the duplicate's
                    // copy affect the original's rows too.
                    dupConfig = WorkspaceConfigManager.remappingWorkspaceAppIdentities(in: dupConfig)
                    if (dupConfig.tasks ?? []).isEmpty && !existing.tasks.isEmpty {
                        if let freshExport = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext) {
                            dupConfig.tasks = freshExport.tasks
                        }
                    }
                    return WorkspaceConfigManager.importWorkspace(from: dupConfig, modelContext: modelContext)
                }
            }
            return WorkspaceConfigManager.importWorkspace(from: config, modelContext: modelContext)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "App", fields: [
                "operation": "import_config",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    private func scheduleTrustPolicyForConfigReplace(
        existing: Workspace,
        configURL: URL
    ) -> WorkspaceConfigManager.ScheduleImportTrustPolicy {
        let configFolderPath = WorkspaceFileLayout.workspaceRoot(forConfigFile: configURL).path
        let existingPath = URL(fileURLWithPath: existing.primaryPath).standardizedFileURL.path
        return configFolderPath == existingPath ? .preserveEnabledState : .quarantineEnabledSchedules
    }

    func createWorkspaceFromFolder(_ url: URL, existingWorkspaces: [Workspace],
                                   askDuplicateAction: (String, Int) -> DuplicateAction) -> Workspace? {
        let name = url.lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        if let existing = existingWorkspaces.first(where: { $0.name == name || $0.primaryPath == url.path }) {
            let action = askDuplicateAction(name, existing.tasks.count)
            switch action {
            case .skip:
                return nil
            case .replace:
                if var exportedConfig = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext) {
                    exportedConfig.name = name
                    exportedConfig.primaryPath = url.path
                    modelContext.delete(existing)
                    return WorkspaceConfigManager.importWorkspace(
                        from: exportedConfig,
                        modelContext: modelContext,
                        scheduleTrustPolicy: .preserveEnabledState
                    )
                }
                modelContext.delete(existing)
                return insertWorkspaceFromFolder(name: name, path: url.path)
            case .duplicate:
                return insertWorkspaceFromFolder(name: name + " (Imported)", path: url.path)
            }
        }
        return insertWorkspaceFromFolder(name: name, path: url.path)
    }

    func insertWorkspaceFromFolder(name: String, path: String) -> Workspace {
        let ws = Workspace(name: name, primaryPath: path)
        modelContext.insert(ws)
        for (sName, sIcon, sAllowed, sBlocked, sBehavior) in [
            ("Read-Only", "eye", ["Read", "Glob", "Grep"], ["Write", "Edit", "Bash"],
             "Do not create, modify, or delete any files."),
            ("Safe Bash", "terminal", Skill.defaultAllowed, [String](),
             "Never run rm, sudo, curl, pip install, npm install, or any destructive/network commands."),
            ("Test Runner", "checkmark.seal", ["Read", "Bash", "Glob", "Grep"], ["Write", "Edit"],
             "Use Bash only to run test commands. Do not modify source code.")
        ] as [(String, String, [String], [String], String)] {
            let skill = Skill(name: sName, icon: sIcon, allowedTools: sAllowed,
                              disallowedTools: sBlocked, behaviorInstructions: sBehavior)
            skill.workspace = ws
            modelContext.insert(skill)
        }
        return ws
    }

    func importSessionsIfNeeded(for workspace: Workspace) {
        // No longer gated on an empty workspace: `importSessions` is idempotent
        // (skips sessions already imported by `sessionId`), so re-running is safe
        // and picks up new sessions without duplicating existing cards.
        let sessions = SessionScanner.discoverSessions(workspacePath: workspace.primaryPath)
        guard !sessions.isEmpty else { return }
        let count = SessionScanner.importSessions(sessions, into: workspace, modelContext: modelContext)
        guard count > 0 else { return }
        AppLogger.audit(.workspaceImported, category: "App", fields: [
            "imported_session_count": String(count),
            "workspace_id": workspace.id.uuidString
        ])
    }

    func backfillGeneratedThreadTitles(
        claudePath: String,
        copilotPath: String = "",
        providerSettings: AgentRuntimeProviderSettings = AgentRuntimeProviderSettings(),
        defaultRuntimeID: String = TaskExecutionDefaults.runtime.rawValue,
        model: String = "claude-haiku-4-5-20251001",
        limit: Int = 40
    ) {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        var resolvedSettings = providerSettings
        if resolvedSettings.executablePath(for: .claudeCode).isEmpty {
            resolvedSettings.setExecutablePath(claudePath.isEmpty ? SpecEngine.detectedClaudePath : claudePath,
                                               for: .claudeCode)
        }
        if resolvedSettings.executablePath(for: .copilotCLI).isEmpty {
            resolvedSettings.setExecutablePath(copilotPath.isEmpty ? CopilotCLIRuntime.detectPath() : copilotPath,
                                               for: .copilotCLI)
        }
        if resolvedSettings.homeDirectory(for: .copilotCLI).isEmpty {
            resolvedSettings.setHomeDirectory(CopilotCLIRuntime.channelHome(), for: .copilotCLI)
        }
        let utilityRuntime = AgentUtilityRuntimeConfiguration(
            runtime: runtime,
            model: RuntimeModelAvailability.normalizedModel(model, for: runtime),
            providerSettings: resolvedSettings
        )
        let executablePath = utilityRuntime.executablePath(for: runtime)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            AppLogger.audit(.taskStats, category: "UI", fields: [
                "operation": "thread_title_backfill",
                "result": "missing_utility_runtime",
                "runtime": runtime.rawValue,
                "executable_path": executablePath
            ], level: .warning)
            return
        }

        let descriptor = FetchDescriptor<AgentTask>(
            sortBy: [SortDescriptor(\AgentTask.updatedAt, order: .reverse)]
        )
        let tasks = (try? modelContext.fetch(descriptor)) ?? []
        let candidates = Array(tasks.filter(Self.shouldBackfillGeneratedTitle).prefix(limit))
        guard !candidates.isEmpty else { return }

        AppLogger.audit(.taskStats, category: "UI", fields: [
            "operation": "thread_title_backfill",
            "candidate_count": String(candidates.count)
        ], level: .info)

        Task { @MainActor in
            var renamed = 0
            for task in candidates {
                guard let workspace = task.workspace else { continue }
                let originalTitle = task.title
                let originalUpdatedAt = task.updatedAt

                guard let generated = await SpecEngine.generateTitle(
                    goal: task.goal,
                    workspacePath: workspace.primaryPath,
                    utilityRuntime: utilityRuntime
                ),
                Self.isUsableGeneratedTitle(generated),
                generated.caseInsensitiveCompare(originalTitle) != .orderedSame else {
                    continue
                }

                task.title = generated
                task.updatedAt = originalUpdatedAt
                renamed += 1
                WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            }

            AppLogger.audit(.taskStats, category: "UI", fields: [
                "operation": "thread_title_backfill",
                "candidate_count": String(candidates.count),
                "renamed_count": String(renamed)
            ], level: .info)
        }
    }

    private static func shouldBackfillGeneratedTitle(_ task: AgentTask) -> Bool {
        guard task.status != .running else { return false }

        // Drafts never appear on the board (they're in-composition plumbing), so
        // don't spend tokens fabricating titles for them.
        guard task.status != .draft else { return false }

        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !goal.isEmpty else { return false }

        let fallbackTitle = fallbackTitle(from: goal)
        let goalPrefix = String(goal.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard title == fallbackTitle || title == goalPrefix else { return false }

        if task.hasProviderSession { return true }
        if title.hasSuffix("...") { return true }
        if title.count > 45 { return true }

        let lowercased = title.lowercased()
        return ["what ", "how ", "why ", "please ", "can you ", "could you "].contains {
            lowercased.hasPrefix($0)
        } || title.contains("?")
    }

    private static func fallbackTitle(from goal: String) -> String {
        let firstLine = goal.components(separatedBy: "\n").first ?? goal
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 60 { return cleaned }

        let prefix = String(cleaned.prefix(57))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    private static func isUsableGeneratedTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 80 else { return false }
        guard !trimmed.contains("\n") else { return false }
        return true
    }

    private static func decodeContractPayload(_ payload: String) -> TaskValidationContractEventPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskValidationContractEventPayload.self, from: data)
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func boundedResumeObjective(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 240 else { return collapsed }
        return String(collapsed.prefix(240)) + "..."
    }

    // MARK: - Migration

    func migrateConnectorCredentials(workspaces: [Workspace], globalConnectors: [Connector] = []) {
        StartupCredentialMigrationService.migrateConnectorCredentials(
            workspaces: workspaces,
            globalConnectors: globalConnectors
        )
    }

    func migrateSkillSecrets(skills: [Skill]) {
        StartupCredentialMigrationService.migrateSkillSecrets(skills: skills)
    }

    // MARK: - Seeding

    func seedSkills(for workspace: Workspace) {
        let readOnly = Skill(
            name: "Read-Only",
            allowedTools: ["Read", "Glob", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: "You must not create, modify, or delete any files. Only read and analyze."
        )
        readOnly.icon = "eye"
        readOnly.skillDescription = "Restricts agent to read-only file access"
        readOnly.workspace = workspace

        let testRunner = Skill(
            name: "Test Runner",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: [],
            behaviorInstructions: "Use Bash only to run test commands (e.g. swift test, pytest, npm test). Do not use Bash for other purposes."
        )
        testRunner.icon = "checkmark.seal"
        testRunner.skillDescription = "Allows all tools but limits Bash to test commands"
        testRunner.workspace = workspace

        let safeBash = Skill(
            name: "Safe Bash",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: [],
            behaviorInstructions: "Never run rm, sudo, curl, pip install, npm install, or any destructive/network commands in Bash."
        )
        safeBash.icon = "terminal"
        safeBash.skillDescription = "Allows all tools but restricts dangerous Bash commands"
        safeBash.workspace = workspace

        for skill in [readOnly, testRunner, safeBash] {
            modelContext.insert(skill)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: workspace,
            modelContext: modelContext,
            auditFields: ["operation": "seed_skills"]
        )
    }

    enum DuplicateAction {
        case skip, replace, duplicate
    }
}
