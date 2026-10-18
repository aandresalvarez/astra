import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@Observable @MainActor
final class TaskLifecycleCoordinator {
    let modelContext: ModelContext
    let taskQueue: TaskQueue
    private let reviewOriginURL: (String) async -> String?
    private let worktreeCleanupStore: TaskWorktreeCleanupStore
    private let workspaceDeletionCleanupStore: WorkspaceDeletionCleanupStore
    private let persistWorkspaceChange: @MainActor (Workspace?, ModelContext) -> Bool
    /// Re-runs a repair's own check before Resume (tests substitute it).
    var repairCheck: @Sendable (RepairAction) async -> Bool = PluginRepairCoordinator.liveCheck

    init(
        modelContext: ModelContext,
        taskQueue: TaskQueue,
        reviewOriginURL: @escaping (String) async -> String? = { path in
            await GitService.shared.getRemoteOriginURL(at: path)
        },
        worktreeCleanupStore: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore(),
        workspaceDeletionCleanupStore: WorkspaceDeletionCleanupStore? = nil,
        persistWorkspaceChange: @escaping @MainActor (Workspace?, ModelContext) -> Bool = { workspace, context in
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context)
        }
    ) {
        self.modelContext = modelContext
        self.taskQueue = taskQueue
        self.reviewOriginURL = reviewOriginURL
        self.worktreeCleanupStore = worktreeCleanupStore
        self.workspaceDeletionCleanupStore = workspaceDeletionCleanupStore ?? WorkspaceDeletionCleanupStore(for: modelContext)
        self.persistWorkspaceChange = persistWorkspaceChange
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
        if taskQueue.hasProcessingLoop || taskQueue.isStopping {
            guard !taskQueue.isStopping else { return }
            // Revoke queue authority synchronously for responsive UI, then
            // drain every queue-owned coroutine before allowing a restart.
            guard taskQueue.cancelAll() else {
                AppLogger.audit(.taskFailed, category: "UI", fields: [
                    "operation": "stop_queue",
                    "reason": "cancellation_persist_failed"
                ], level: .error)
                return
            }
            let summary = TaskRunLifecycleService.cancelAllRunningTasks(modelContext: modelContext)
            AppLogger.audit(.taskCancelled, category: "UI", fields: [
                "source": "queue_toggle",
                "running_runs_cancelled": String(summary.runsUpdated),
                "tasks_cancelled": String(summary.tasksUpdated)
            ])
            Task { @MainActor [taskQueue] in
                await taskQueue.cancelAllAndWait()
            }
            return
        }
        taskQueue.registerLifecycleTask(modelContext: modelContext) { [taskQueue] modelContext in
            await taskQueue.processQueue(modelContext: modelContext)
            guard !Task.isCancelled else { return }
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
        let activeRequests: [TaskTurnRequest]
        do {
            activeRequests = try TaskTurnRequestRepository.activeRequests(for: task, in: modelContext)
        } catch {
            return Task {}
        }
        let request: TaskTurnRequest
        if let existing = activeRequests.first {
            guard existing.kind == .initial || existing.kind == .scheduled || existing.kind == .retry else {
                AppLogger.audit(.taskStats, category: "UI", taskID: task.id, fields: [
                    "event": "manual_run_rejected",
                    "active_request_kind": existing.kind.rawValue
                ], level: .warning)
                return Task {}
            }
            request = existing
        } else {
            guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(
                for: task,
                into: modelContext
            ), let saved = try? TaskTurnRequestRepository.request(id: submission.requestID, in: modelContext) else {
                return Task {}
            }
            request = saved
        }
        let launch = taskQueue.signalExecutionRequest(
            id: request.id,
            task: task,
            modelContext: modelContext
        )
        let taskID = task.id
        return taskQueue.registerLifecycleTask(modelContext: modelContext) { modelContext in
            await launch.value
            guard !Task.isCancelled else { return }
            let tasks = try? modelContext.fetch(
                FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
            )
            guard let refreshedTask = tasks?.first else { return }
            AppLogger.audit(.taskCompleted, category: "UI", taskID: taskID, fields: [
                "status": refreshedTask.status.rawValue
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
        // After an expired sign-in, Retry continues the stopped session like
        // Resume, so it waits for the same check (`resumeTask`).
        let latest = task.runs.max(by: { $0.startedAt < $1.startedAt })
        guard latest?.typedStopReason == .capabilitySessionExpired,
              var repair = pendingRepair(for: task), repair.checkBinary != nil else {
            return retryVerifiedTask(task)
        }
        repair.checkEnvironment = Self.projectedCheckEnvironment(for: task, binary: repair.checkBinary)
        repair = CLISessionExpiryClassifier.checkingLaunchHost(repair)
        let check = repairCheck
        let origin = RepairCheckOrigin(task)
        return Task { @MainActor [weak self] in
            let works = await check(repair)
            guard let self, origin.stillHolds(for: task, audit: .taskRetried) else { return }
            if works {
                _ = self.retryVerifiedTask(task)
            } else {
                self.recordRepairStillNeeded(task, repair: repair, action: "retried")
            }
        }
    }

    private func retryVerifiedTask(_ task: AgentTask) -> Task<Void, Never>? {
        // A durable submission leaves the task's terminal status untouched
        // while it waits, so status-gated Retry surfaces can still fire.
        // Starting a second continuation here would race the pending
        // admission into out-of-order or duplicate execution.
        if let activeTurns = try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext),
           let activeTurn = activeTurns.first {
            AppLogger.audit(.taskRetried, category: "UI", taskID: task.id, fields: [
                "retry_mode": "rejected_active_turn",
                "active_request_id": activeTurn.id.uuidString,
                "active_request_state": activeTurn.state.rawValue
            ], level: .warning)
            return nil
        }
        let retryTurn = latestRetryableTurnRequest(for: task)
        let durableMessageEventIDs = Set(
            (try? TaskTurnRequestRepository.requests(for: task, in: modelContext))?.map(\.messageEventID) ?? []
        )
        let retrySource = retryTurn.flatMap { retryLaunchSource(for: $0, task: task) }
            ?? Self.latestRetryableFollowUpMessage(for: task, excludingMessageEventIDs: durableMessageEventIDs)
                .map { RetryLaunchSource.userTurn($0) }
        let retryFollowUpMessage = retrySource?.userTurnMessage
        // A first run the user (or an ASTRA restart) cut short still has a
        // provider session. Retry continues it rather than relaunching the
        // initial prompt into a brand-new session.
        // After an expired plugin sign-in the turn, follow-up or not, resumes
        // where it stopped: resending the follow-up would repeat its writes.
        let afterExpiry = task.runs.max(by: { $0.startedAt < $1.startedAt })?.typedStopReason == .capabilitySessionExpired
        let interruptedResumeMessage = retryFollowUpMessage == nil || afterExpiry
            ? interruptedRunResumeMessage(for: task, retryTurn: retryTurn, acceptsFollowUp: afterExpiry)
            : nil
        let launchMessage = afterExpiry
            ? interruptedResumeMessage ?? retryFollowUpMessage
            : retryFollowUpMessage ?? interruptedResumeMessage
        let retryMode = interruptedResumeMessage != nil
            ? "interrupted_resume"
            : (launchMessage == nil ? "initial_task" : "continuation")
        AppLogger.audit(.taskRetried, category: "UI", taskID: task.id, fields: [
            "retry_mode": retryMode
        ])
        let snapshot = ExecutionMutationSnapshot(task)
        let continuation = launchMessage != nil
        let result = ExecutionRequestSubmissionService.submitRetry(
            message: launchMessage,
            continuation: continuation,
            for: task,
            into: modelContext,
            prepare: {
                TaskStateMachine.enqueueFromRetry(task, modelContext: modelContext)
                if !continuation {
                    task.tokensUsed = 0
                    task.costUSD = 0
                }
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Task.retried,
                    payload: interruptedResumeMessage != nil
                        ? "Interrupted run re-queued — resuming the previous session."
                        : (continuation ? "Latest follow-up re-queued for retry." : "Task re-queued for retry.")
                ))
            },
            rollback: { snapshot.restore(task, in: modelContext) }
        )
        guard case .success(let submission) = result else { return nil }
        return taskQueue.signalExecutionRequest(
            id: submission.requestID,
            task: task,
            modelContext: modelContext
        )
    }

    /// The continuation message Retry sends when the latest run was cut short
    /// (cancelled by the user, queue stop, or ASTRA restart) and its provider
    /// session can be picked up again; nil keeps Retry a from-scratch relaunch.
    ///
    /// Deliberately narrow: failed runs keep their own Resume action and a
    /// from-scratch Retry, an approved-plan run must relaunch through the plan
    /// path, and a runtime without native resume would only get a thinner
    /// prompt than the initial one. Whether the session is actually resumable
    /// is the worker's call; if not, it falls back to a history-carrying prompt.
    private func interruptedRunResumeMessage(for task: AgentTask, retryTurn: TaskTurnRequest?, acceptsFollowUp: Bool = false) -> String? {
        guard task.hasProviderSession,
              AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: task.resolvedRuntimeID),
              let latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt }),
              // A session belongs to the runtime that opened it: after a runtime switch the worker
              // drops it, so Retry must take the from-scratch path with its reset instead.
              latestRun.runtimeID == task.resolvedRuntimeID.rawValue,
              let stopReason = latestRun.typedStopReason,
              // A run stopped for an expired plugin sign-in resumes after the
              // repair, so work it already did (external writes) isn't replayed.
              [.cancelled, .appRestarted, "queue_cancelled", .capabilitySessionExpired].contains(stopReason),
              // A from-scratch run cut off before its init frame never learned a session, while
              // task.sessionId can still name an older run's: only a run that owns it can be resumed.
              let runSession = latestRun.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runSession.isEmpty,
              runSession == task.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // Scheduled, chained and approved-plan launches keep their own relaunch path.
        guard task.originScheduleID == nil, task.chainedFromID == nil else { return nil }
        if let retryTurn {
            guard retryTurn.kind == .initial || retryTurn.kind == .retry || (acceptsFollowUp && retryTurn.kind == .followUp)
            else { return nil }
            if let sourceEvent = task.events.first(where: { $0.id == retryTurn.sourceEventID }),
               let source = ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent),
               // After an expired sign-in a follow-up, or a retry that was
               // itself continuing one, resumes rather than replays.
               (source.launchMode != .initial
                    && !(acceptsFollowUp && (retryTurn.kind == .followUp || source.launchMode == .continuation)))
                || source.planSnapshot != nil
                || source.scheduleID != nil || source.sourceTaskID != nil {
                return nil
            }
        }
        return Self.resumeContinuationMessage(for: task)
    }

    /// The durable turn Retry may resurrect: the task's newest request, only
    /// when it is failed/cancelled AND still represents the task's latest
    /// failure. A run started after the request terminalized (a resume,
    /// approved-plan, or base-task attempt) means Retry must target THAT
    /// failure through the legacy fallbacks — resurrecting an older durable
    /// message would execute stale instructions.
    private func latestRetryableTurnRequest(for task: AgentTask) -> TaskTurnRequest? {
        guard let requests = try? TaskTurnRequestRepository.requests(for: task, in: modelContext),
              let candidate = requests.last,
              candidate.state == .failed || candidate.state == .cancelled else {
            return nil
        }
        let latestRunStart = task.runs.map(\.startedAt).max() ?? .distantPast
        guard (candidate.terminalAt ?? .distantFuture) >= latestRunStart else { return nil }
        return candidate
    }

    /// What the retry candidate represents, which decides Retry's launch mode.
    private enum RetryLaunchSource {
        /// A user turn to replay — Retry re-sends it as a continuation.
        case userTurn(String)
        /// An internal launch (initial, scheduled, chained, or approved plan)
        /// whose typed envelope carries no user turn. Retry must relaunch it in
        /// initial mode instead of inventing a continuation.
        case internalLaunch

        var userTurnMessage: String? {
            guard case .userTurn(let message) = self else { return nil }
            return message
        }
    }

    /// Resolves the retry candidate's source event into a launch mode.
    ///
    /// A typed source envelope only decodes for internal execution-request
    /// events, and the internal *launch* kinds legitimately encode
    /// `message == nil` — only a user follow-up (retry continuation, resume,
    /// permission resume) carries one. Collapsing that nil into the raw
    /// `event.payload` would hand the provider the JSON envelope itself as
    /// conversation text AND flip `retryTask` into continuation mode, skipping
    /// the initial-run budget reset the accepted launch is owed. Falling
    /// through to the legacy chat fallback would be just as wrong: the newest
    /// failure IS this internal launch, so an older user message must not
    /// supersede it. Events with no envelope at all (legacy plain-text
    /// `user.message` sources) keep replaying their payload as before.
    private func retryLaunchSource(for request: TaskTurnRequest, task: AgentTask) -> RetryLaunchSource? {
        guard let event = task.events.first(where: { $0.id == request.messageEventID }) else { return nil }
        if let source = ExecutionRequestSubmissionService.decodeSourcePayload(event) {
            guard let message = source.message else { return .internalLaunch }
            return .userTurn(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .userTurn(event.payload.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    /// After a stop for an expired sign-in, Resume first re-runs that
    /// repair's check: resuming before the sign-in finished would start a run
    /// that fails its pre-launch check, and that newer run would no longer
    /// carry the repair. When the check fails, the task records why and stays
    /// on the stopped run, whose repair is still offered.
    func resumeTask(_ task: AgentTask) -> Task<Void, Never>? {
        guard var repair = pendingRepair(for: task), repair.checkBinary != nil else {
            return resumeVerifiedTask(task)
        }
        repair.checkEnvironment = Self.projectedCheckEnvironment(for: task, binary: repair.checkBinary)
        repair = CLISessionExpiryClassifier.checkingLaunchHost(repair)
        let check = repairCheck
        let origin = RepairCheckOrigin(task)
        return Task { @MainActor [weak self] in
            let works = await check(repair)
            guard let self, origin.stillHolds(for: task, audit: .taskResumed) else { return }
            if works {
                _ = self.resumeVerifiedTask(task)
            } else {
                self.recordRepairStillNeeded(task, repair: repair)
            }
        }
    }

    /// The task as Resume or Retry found it before the repair check, which can
    /// take seconds. If the person closed or deleted the task meanwhile, or a
    /// newer run started or the status moved on, the check's answer is about a
    /// task they already left, so nothing continues and nothing is recorded.
    private struct RepairCheckOrigin {
        let taskID: UUID
        let status: TaskStatus
        let isDone: Bool
        let latestRunID: UUID?

        init(_ task: AgentTask) {
            taskID = task.id
            status = task.status
            isDone = task.isDone
            latestRunID = task.runs.max(by: { $0.startedAt < $1.startedAt })?.id
        }

        @MainActor
        func stillHolds(for task: AgentTask, audit event: AuditEvent) -> Bool {
            let reason: String? = if task.isDeleted || task.modelContext == nil {
                "task_deleted"
            } else if task.isDone != isDone {
                "task_closed"
            } else if task.status != status {
                "status_changed"
            } else if task.runs.max(by: { $0.startedAt < $1.startedAt })?.id != latestRunID {
                "newer_run"
            } else {
                nil
            }
            guard let reason else { return true }
            AppLogger.audit(event, category: "UI", taskID: taskID, fields: [
                "outcome": "skipped_after_repair_check",
                "reason": reason
            ], level: .warning)
            return false
        }
    }

    private static let gitHubCheckVariables: Set<String> = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_REPO", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
        "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "PATH"
    ]

    /// The variables the resumed run gives the checked CLI, so a repair check
    /// judges the credentials that run gets: for `gh` its token variables
    /// (which override any sign-in), the GitHub Enterprise host and
    /// tokens (`GH_HOST`, else `GH_REPO`'s host, picks the host), the
    /// configuration directory its stored login lives in (`GH_CONFIG_DIR`,
    /// else `XDG_CONFIG_HOME`) and the `PATH` that finds the binary, for
    /// `gcloud` the whole stripped launch environment, where
    /// `CLOUDSDK_CONFIG`, `CLOUDSDK_CORE_ACCOUNT` or
    /// `GOOGLE_APPLICATION_CREDENTIALS` pick the account it uses. Built from
    /// the same launch scope as the run, detached skill snapshots included: a
    /// snapshot whose skill was removed still delivers its variables.
    /// `binary` may be the path of the installation that failed; its name
    /// picks the variables.
    static func projectedCheckEnvironment(for task: AgentTask, binary: String?) -> [String: String]? {
        let binary = binary.map { ($0 as NSString).lastPathComponent }
        guard binary == "gh" || binary == "gcloud" else { return nil }
        let scope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: Self.resumeContinuationMessage(for: task),
            runtime: task.resolvedRuntimeID
        ).providerLaunch
        var launchEnvironment = scope.resolver.resolvedEnvironmentVariables
        BrokeredConnectorEnvironment.strip(from: &launchEnvironment, capabilityScope: scope)
        let environment = launchEnvironment.filter { key, value in
            !value.isEmpty && (binary == "gcloud" || Self.gitHubCheckVariables.contains(key))
        }
        return environment.isEmpty ? nil : environment
    }

    /// The repair the task's latest run stopped for, if it stopped for one.
    /// A stop whose fix is outside ASTRA (a rejected `GH_TOKEN`) records no
    /// repair to offer, but its check is still the one Resume and Retry run.
    func pendingRepair(for task: AgentTask) -> RepairAction? {
        guard let run = task.runs.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        if let recorded = task.events
            .last(where: { $0.run?.id == run.id && $0.type == TaskEventTypes.System.runtimeRepairRequired.rawValue })
            .flatMap({ RepairAction.decode(from: $0.payload) }) {
            return recorded
        }
        guard run.typedStopReason == .capabilitySessionExpired else { return nil }
        let stopMessage = task.events
            .last { $0.run?.id == run.id && $0.type == TaskEventTypes.System.error.rawValue }?
            .payload
        return CLISessionExpiryClassifier.family(forStopMessage: stopMessage)?.repair
    }

    private func recordRepairStillNeeded(_ task: AgentTask, repair: RepairAction, action: String = "resumed") {
        let run = task.runs.max(by: { $0.startedAt < $1.startedAt })
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: "\(repair.componentName) still isn't working, so the task wasn't \(action). \(repair.detail)",
            run: run
        ))
        _ = persistWorkspaceChange(task.workspace, modelContext)
    }

    private func resumeVerifiedTask(_ task: AgentTask) -> Task<Void, Never>? {
        if LegacyApprovedPermissionContinuation.isAvailable(task: task) {
            guard let submission = LegacyApprovedPermissionContinuation.submit(task: task, modelContext: modelContext) else { return nil }
            return taskQueue.signalExecutionRequest(id: submission.requestID, task: task, modelContext: modelContext)
        }
        guard task.hasProviderSession else {
            AppLogger.audit(.workerSessionCleared, category: "UI", taskID: task.id, fields: [
                "reason": "missing_session_id"
            ], level: .warning)
            return nil
        }
        guard (try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext).isEmpty) == true else {
            return nil
        }
        AppLogger.audit(.taskResumed, category: "UI", taskID: task.id)
        let snapshot = ExecutionMutationSnapshot(task)
        let result = ExecutionRequestSubmissionService.submitResume(
            message: Self.resumeContinuationMessage(for: task),
            for: task,
            into: modelContext,
            prepare: {
                task.updatedAt = Date()
                task.markRead()
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Task.resumed,
                    payload: "Resuming previous session — continuing where the agent left off."
                ))
            },
            rollback: { snapshot.restore(task, in: modelContext) }
        )
        guard case .success(let submission) = result else { return nil }
        return taskQueue.signalExecutionRequest(id: submission.requestID, task: task, modelContext: modelContext)
    }

    @discardableResult
    func approveTask(_ task: AgentTask) -> Task<Void, Never>? {
        if hasOpenRuntimePermissionApprovalRequest(task) {
            return approveRuntimePermissionAndContinue(task)
        }

        if task.runs.max(by: { $0.startedAt < $1.startedAt })?.typedStopReason == .permissionApprovalRequired {
            return nil
        }

        if let latestRun = dismissibleLatestRun(for: task) {
            dismissWithoutMarkingCompleted(task, latestRun: latestRun)
            return nil
        }

        let latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt })
        if let latestRun, GitHubReviewPublicationRequirement.needsOriginTargetBinding(task: task) {
            let expectedStatus = task.status
            return Task { @MainActor in
                await GitHubReviewPublicationRequirement.bindOriginTargetIfNeeded(
                    task: task, run: latestRun, modelContext: self.modelContext,
                    originURL: self.reviewOriginURL
                )
                guard task.status == expectedStatus else { return }
                self.finishApprovalAfterReviewTargetResolution(task, latestRun: latestRun)
            }
        }
        finishApprovalAfterReviewTargetResolution(task, latestRun: latestRun)
        return nil
    }

    private func finishApprovalAfterReviewTargetResolution(_ task: AgentTask, latestRun: TaskRun?) {
        if let latestRun,
           TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: latestRun) != nil
            || GitHubReviewPublicationRequirement.isPending(task: task) {
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
                return
            }
        }

        // Approving a task that is already complete decides nothing, and the
        // transition would still stamp a fresh `completedAt`, insert another
        // "Task approved by user." event, and save and export the workspace.
        // One user clicked an approve control that did nothing 40 times in 35
        // seconds (task BA13BF87) and each click did exactly that. This sits
        // after the completion block above, which can still reopen a task
        // whose external outcome is pending.
        guard task.status != .completed else {
            AppLogger.audit(.taskApproved, category: "UI", taskID: task.id, fields: [
                "approval_type": "completion_ignored",
                "reason": "already_completed"
            ], level: .debug)
            return
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

    /// Approval owns its continuation intent even when the provider already exited.
    @discardableResult
    func approveSimilarRuntimePermissionForTask(_ task: AgentTask) -> Task<Void, Never>? {
        resolveRuntimePermission(task, scope: .task)
    }

    private func approveRuntimePermissionAndContinue(_ task: AgentTask) -> Task<Void, Never>? {
        resolveRuntimePermission(task, scope: .once)
    }

    private func resolveRuntimePermission(_ task: AgentTask, scope: PermissionApprovalResolutionService.Scope) -> Task<Void, Never>? {
        let outcome = PermissionApprovalResolutionService.approve(
            task: task, scope: scope, modelContext: modelContext,
            heldGrants: oneRunGrantsHeldByPausedRequest(for: task)
        )
        if case .queued(let submission) = outcome {
            return taskQueue.signalExecutionRequest(id: submission.requestID, task: task, modelContext: modelContext)
        }
        return nil
    }

    /// What the user already allowed once for the request that is paused now.
    ///
    /// Those grants travel only inside the relaunch's own execution request, so
    /// when the relaunch pauses again the next approval has to carry them
    /// forward or they are lost: production task 06E0814E alternated between
    /// two connectors for twelve approvals that way. Only the paused request's
    /// own relaunch counts. A new message is a new request that starts with
    /// nothing carried, which is what keeps an old approval from being replayed.
    private func oneRunGrantsHeldByPausedRequest(for task: AgentTask) -> [PermissionGrant] {
        guard let pausedRun = task.runs.max(by: { $0.startedAt < $1.startedAt }),
              pausedRun.typedStopReason == .permissionApprovalRequired,
              let requests = try? TaskTurnRequestRepository.requests(for: task, in: modelContext),
              let request = requests.last(where: { $0.runID == pausedRun.id }),
              let sourceEvent = task.events.first(where: { $0.id == request.sourceEventID }),
              sourceEvent.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue,
              let source = ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent) else {
            return []
        }
        return PermissionBroker.oneRunGrantsCarriedWithinRequest(
            source.executionPolicyOverride?.permissionGrants ?? []
        )
    }

    private static func latestRetryableFollowUpMessage(
        for task: AgentTask,
        excludingMessageEventIDs: Set<UUID> = []
    ) -> String? {
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message = latestActionableUserMessage(
            for: task,
            excludingMessageEventIDs: excludingMessageEventIDs
        ) else { return nil }
        return message == goal ? nil : message
    }

    private static func latestActionableUserMessage(
        for task: AgentTask,
        before cutoff: Date = Date.distantFuture,
        excludingMessageEventIDs: Set<UUID> = []
    ) -> String? {
        task.events
            .filter { $0.type == "user.message" }
            .filter { $0.timestamp <= cutoff }
            .filter { !excludingMessageEventIDs.contains($0.id) }
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

    /// Turn requests reference their task by scalar id, so neither the
    /// workspace→task cascade nor task deletion reaches them. Cancel first —
    /// terminalizing every active request makes a waiting admission coroutine
    /// exit instead of resuming provider work for a task that no longer
    /// exists — then remove the rows so terminal history doesn't accumulate
    /// as permanent orphans.
    ///
    /// Stopping a worker is not reversible, so a deletion first saves its
    /// tasks' requests as cancelled and stops their workers only once that
    /// save succeeds. When it fails, the requests get their previous values
    /// back, nothing is stopped, and the deletion does not proceed. The
    /// fields are restored explicitly rather than by `rollback()`, which
    /// would leave stale model properties and discard unrelated edits.
    ///
    /// Returns every request row of the tasks, for the deletion to remove,
    /// or nil when they can't be read: a failed lookup would otherwise stop
    /// workers with nothing cancelled and leave rows orphaned.
    private func cancelDurably(_ tasks: [AgentTask]) -> [TaskTurnRequest]? {
        typealias Snapshot = (
            request: TaskTurnRequest, state: TaskTurnRequestState, blockingTaskID: UUID?,
            blockerSummary: String?, terminalAt: Date?, terminalReason: String?
        )
        var active: [TaskTurnRequest] = []
        var allRequests: [TaskTurnRequest] = []
        do {
            for task in tasks {
                active += try TaskTurnRequestRepository.activeRequests(for: task, in: modelContext)
                allRequests += try TaskTurnRequestRepository.requests(for: task, in: modelContext)
            }
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", taskID: tasks.first?.id, fields: [
                "reason": "deletion_request_lookup_failed", "error": error.localizedDescription
            ], level: .error)
            return nil
        }
        var snapshots: [Snapshot] = []
        for request in active {
            snapshots.append((
                request, request.state, request.blockingTaskID,
                request.blockerSummary, request.terminalAt, request.terminalReason
            ))
            _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "cancelled_by_user")
        }
        if !snapshots.isEmpty, !persistWorkspaceChange(tasks.first?.workspace, modelContext) {
            for snapshot in snapshots {
                snapshot.request.state = snapshot.state
                snapshot.request.blockingTaskID = snapshot.blockingTaskID
                snapshot.request.blockerSummary = snapshot.blockerSummary
                snapshot.request.terminalAt = snapshot.terminalAt
                snapshot.request.terminalReason = snapshot.terminalReason
            }
            AppLogger.audit(.taskFailed, category: "Persistence", taskID: tasks.first?.id, fields: [
                "reason": "deletion_cancellation_save_failed",
                "request_count": String(snapshots.count)
            ], level: .error)
            return nil
        }
        // The requests are durably cancelled; without a context, `cancel`
        // only stops the worker and wakes waiters.
        for task in tasks { taskQueue.cancel(task: task) }
        return allRequests
    }

    /// Workers are stopped once their cancellation is saved, before the
    /// deletion itself. When the deletion then isn't saved, the surviving
    /// tasks are settled rather than left looking like they still run with
    /// no worker or request behind them: a running task is cancelled the way
    /// Cancel does it, and a queued one goes back to draft.
    private func settleAfterUnsavedDeletion(_ tasks: [AgentTask]) {
        for task in tasks where !task.isDeleted {
            switch task.status {
            case .running, .pendingUser:
                let summary = TaskRunLifecycleService.cancelTask(task, modelContext: modelContext, source: .userAction)
                TaskRunLifecycleService.persist(summary: summary, modelContext: modelContext)
            case .queued:
                TaskStateMachine.restoreDraftForEditing(task, modelContext: modelContext)
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: task.workspace, modelContext: modelContext, taskID: task.id,
                    auditFields: ["operation": "unsaved_deletion_settled"]
                )
            default:
                break
            }
        }
    }

    /// Deletes `task` and returns whether the deletion was saved. `willDelete`
    /// runs only once any worktree cleanup intent is durable, just before the
    /// task is deleted. A false result means the task is still stored and back
    /// in the context, so the UI must keep showing it.
    @discardableResult
    func deleteTask(_ task: AgentTask, willDelete: () -> Void = {}) -> Bool {
        AppLogger.audit(.taskDeleted, category: "UI", taskID: task.id)
        let workspace = task.workspace
        // A draft that never ran gives back its untouched worktrees, including
        // one it was retargeted away from; any other task's worktree holds the
        // user's work and is kept.
        let unusedWorktrees = task.status == .draft && task.runs.isEmpty
            ? TaskWorktreeService.discardSnapshots(for: task, ownership: worktreeCleanupStore.ownership)
            : []
        guard let requests = cancelDurably([task]) else { return false }
        let persisted = TaskWorktreeService.saveDeletionThenDiscard(
            unusedWorktrees, workspace: workspace, modelContext: modelContext, resourceQueue: taskQueue,
            cleanupStore: worktreeCleanupStore,
            delete: {
                willDelete()
                // Removed inside the deletion, so a failed save rolls it back.
                for request in requests { modelContext.delete(request) }
                modelContext.delete(task)
            }
        ).persisted
        if !persisted { settleAfterUnsavedDeletion([task]) }
        return persisted
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

    func deleteWorkspace(_ ws: Workspace, existingWorkspaces: [Workspace]) -> (
        persisted: Bool, nextWorkspace: Workspace?, cleanup: Task<Bool, Never>?
    ) {
        let next = existingWorkspaces.first(where: { $0.id != ws.id })
        // Mirrors and Keychain items can't be rolled back, so they are removed
        // only once the deletion is saved. What to remove is recorded first,
        // so a quit after the save is finished at the next launch.
        // What is stored may include a cleanup still pending for this same
        // deletion; settling uses all of it, and a rollback puts it back.
        let store = workspaceDeletionCleanupStore
        let previousRecord: WorkspaceDeletionCleanupRecord?
        let cleanupRecord: WorkspaceDeletionCleanupRecord
        do {
            let snapshot = WorkspaceDeletionCleanupRecord(ws)
            previousRecord = try store.existing(matching: snapshot)
            cleanupRecord = try store.record(snapshot)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "deletion_cleanup_record_failed",
                "error": error.localizedDescription
            ], level: .error)
            return (false, nil, nil)
        }
        // The store mark a reused record had before this attempt, put back
        // with the record if the deletion isn't saved.
        var previousStoreMark: Data?
        func restoreRecord() {
            do {
                try store.restore(previousRecord, replacing: cleanupRecord)
                if previousRecord != nil { store.restoreStoreMark(cleanupRecord, previous: previousStoreMark) }
            } catch {
                AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "operation": "delete_workspace", "reason": "deletion_cleanup_restore_failed",
                    "error": error.localizedDescription
                ], level: .error)
            }
        }
        do {
            // Without the store's identity a retry couldn't tell this deletion
            // saved, so one that can't be identified isn't deleted.
            guard let identity = PersistentStoreIdentity.current(for: modelContext) else {
                throw CocoaError(.fileReadUnknown)
            }
            previousStoreMark = try store.markStore(cleanupRecord, identity: identity)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "deletion_cleanup_record_failed",
                "error": error.localizedDescription
            ], level: .error)
            restoreRecord()
            return (false, nil, nil)
        }
        guard let requests = cancelDurably(ws.tasks) else {
            restoreRecord()
            return (false, nil, nil)
        }
        // The mirrors must stop changing before the deletion is saved, so
        // their identities are durable in the same step a quit could follow:
        // queued exports of this workspace, the cancellation's included, are
        // retired, then the identities pinned. A rollback re-exports.
        WorkspaceAutoExportGate.shared.retire(workspaceID: cleanupRecord.workspaceID.uuidString)
        let pinned: WorkspaceDeletionCleanupRecord
        do {
            pinned = try store.pinMirrorIdentities(for: cleanupRecord)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "mirror_identity_unpinned",
                "error": error.localizedDescription
            ], level: .error)
            restoreRecord()
            settleAfterUnsavedDeletion(ws.tasks)
            WorkspaceConfigManager.autoExport(workspace: ws, modelContext: modelContext)
            return (false, nil, nil)
        }
        let result = TaskWorktreeService.saveDeletionThenDiscard(
            unusedDraftWorktrees(in: ws), workspace: next, modelContext: modelContext, resourceQueue: taskQueue,
            cleanupStore: worktreeCleanupStore,
            delete: {
                for request in requests { modelContext.delete(request) }
                modelContext.delete(ws)
            },
            persist: persistWorkspaceChange
        )
        // Cancellation exports mirrors, so they are removed only after it and
        // the deletion are saved. An unsaved deletion owes nothing new.
        if result.persisted {
            // Marked saved before anything is removed, so a retry after a quit
            // knows the deletion happened. Without the mark, as after a quit
            // just before it, a retry against the same store still knows.
            do {
                try store.markCommitted(pinned)
            } catch {
                AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "operation": "delete_workspace", "reason": "commit_mark_unwritable",
                    "error": error.localizedDescription
                ], level: .error)
            }
            // Settled now only while recovery vouches for the store's owners;
            // otherwise the trusted launch's retry settles it. What other
            // pending deletions and unconfirmed connector intents hold is
            // spared, and while any of those can't be read, the retry does it.
            // Every mirror the launch's recovery loaded is passed too: a copy
            // of this workspace's goes with it, and any other one keeps the
            // connectors and skills it lists.
            let deleting = Set(store.pending().map(\.workspaceID))
            if WorkspaceRecoveryTrust.allowsCleanup,
               let others = store.records(pendingBesides: pinned),
               let intentOwners = ConnectorCredentialCleanup.unconfirmedOwners(
                   modelContext: modelContext, excludingWorkspaceIDs: deleting
               ),
               let mirrored = ConnectorCredentialCleanup.connectorsInStoredMirrors(
                   modelContext: modelContext, excludingWorkspaceIDs: deleting
               ),
               WorkspaceDeletionCleanupService.settle(
                   pinned, modelContext: modelContext,
                   retained: others.flatMap(\.connectors) + intentOwners,
                   retainedSkillIDs: Set(others.flatMap { $0.skills.map(\.skillID) }).union(mirrored.skillIDs),
                   movedMirrors: WorkspaceRecoveryTrust.loadedMirrors
               ) {
                store.remove(pinned)
            }
        } else {
            restoreRecord()
            settleAfterUnsavedDeletion(ws.tasks)
            WorkspaceConfigManager.autoExport(workspace: ws, modelContext: modelContext)
        }
        return (result.persisted, result.persisted ? next : nil, result.cleanup)
    }

    private func unusedDraftWorktrees(in workspace: Workspace) -> [TaskWorktreeDiscard] {
        workspace.tasks.filter { $0.status == .draft && $0.runs.isEmpty }.flatMap {
            TaskWorktreeService.discardSnapshots(for: $0, ownership: worktreeCleanupStore.ownership)
        }
    }

    /// Replacements save the new reference graph before any checkout is
    /// removed, so imported tasks keep worktrees they take over.
    /// `afterCancellation` runs once the existing workspace's turn requests
    /// are durably cancelled and its tasks settled, before anything is
    /// deleted, so an export taken there never restores a stopped run.
    private func replaceWorkspace(
        _ existing: Workspace, replacementPath: String, afterCancellation: () -> Void = {}, create: () -> Workspace
    ) -> Workspace? {
        var replacement: Workspace?
        // The import writes the replacement's SSH connections, at its own
        // path, before the save. Both files are captured first and put back
        // if the replacement isn't saved; one that can't be read stops it.
        var sshSnapshots: [(path: String, data: SSHConnectionManager.Snapshot)] = []
        for path in Set([existing.primaryPath, replacementPath]) {
            do {
                sshSnapshots.append((path, try SSHConnectionManager.snapshot(workspacePath: path)))
            } catch {
                AppLogger.audit(.workspaceRecoveryFailed, category: "App", fields: [
                    "operation": "replace_workspace", "reason": "ssh_snapshot_failed",
                    "error": error.localizedDescription
                ], level: .error)
                return nil
            }
        }
        guard let requests = cancelDurably(existing.tasks) else { return nil }
        // The settling a failed replacement applies, done first: an export of
        // the workspace would otherwise still show its runs as running.
        settleAfterUnsavedDeletion(existing.tasks)
        afterCancellation()
        let existingID = existing.id.uuidString
        let result = TaskWorktreeService.saveDeletionThenDiscard(
            unusedDraftWorktrees(in: existing), workspace: nil, modelContext: modelContext, resourceQueue: taskQueue,
            cleanupStore: worktreeCleanupStore,
            delete: {
                for request in requests { modelContext.delete(request) }
                // Mirror writes queued for the old workspace, the
                // cancellation's included, must not land after the
                // replacement's own export.
                WorkspaceAutoExportGate.shared.retire(workspaceID: existingID)
                modelContext.delete(existing)
                replacement = create()
            },
            persist: { _, context in
                persistWorkspaceChange(replacement, context)
            }
        )
        guard result.persisted else {
            settleAfterUnsavedDeletion(existing.tasks)
            for snapshot in sshSnapshots {
                do {
                    try SSHConnectionManager.restore(snapshot.data, workspacePath: snapshot.path)
                } catch {
                    // Not retried later: replaying an old file at the next
                    // launch could overwrite edits made in between. The old
                    // file is kept beside it instead, for the user to take back.
                    var fields = [
                        "operation": "replace_workspace", "reason": "ssh_restore_failed",
                        "path": SSHConnectionManager.connectionsFilePath(for: snapshot.path),
                        "error": error.localizedDescription
                    ]
                    do {
                        if let copy = try SSHConnectionManager.preserveUnrestored(snapshot.data, workspacePath: snapshot.path) {
                            fields["recovery_copy"] = copy
                        }
                    } catch {
                        fields["recovery_copy_error"] = error.localizedDescription
                    }
                    AppLogger.audit(.workspaceRecoveryFailed, category: "App", fields: fields, level: .error)
                }
            }
            // The writes it retired are replaced by one current export, taken
            // after the SSH files are back, since the export reads them.
            WorkspaceConfigManager.autoExport(workspace: existing, modelContext: modelContext)
            return nil
        }
        return replacement
    }

    func importFromConfig(at url: URL, existingWorkspaces: [Workspace],
                          askDuplicateAction: (String, Int) -> DuplicateAction) -> Workspace? {
        do {
            var config = try WorkspaceConfigManager.loadConfig(from: url)
            config.primaryPath = WorkspaceFileLayout.workspaceRoot(forConfigFile: url).path
            if refusesRoot(WorkspaceConfigManager.reservedRoot(of: config), operation: "import_config") { return nil }
            let configID = config.id
            if let existing = existingWorkspaces.first(where: { workspace in
                (configID != nil && workspace.id.uuidString == configID) || workspace.primaryPath == config.primaryPath
            }) {
                let action = askDuplicateAction(config.name, existing.tasks.count)
                // Cleanup can start while the prompt is open; check again
                // before replacing anything.
                if action != .skip,
                   refusesRoot(WorkspaceConfigManager.reservedRoot(of: config), operation: "import_config") {
                    return nil
                }
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
                    return replaceWorkspace(existing, replacementPath: config.primaryPath) {
                        WorkspaceConfigManager.importWorkspace(
                            from: config, modelContext: modelContext, scheduleTrustPolicy: scheduleTrustPolicy,
                            capabilityTrust: .validate(.live())
                        )
                    }
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
                    // The file's projected skill IDs (in its templates and
                    // schedules) were derived from the ID cleared above.
                    return WorkspaceConfigManager.importWorkspace(
                        from: dupConfig, modelContext: modelContext, capabilityTrust: .validate(.live()),
                        sourceWorkspaceID: configID.flatMap(UUID.init(uuidString:))
                    )
                }
            }
            return WorkspaceConfigManager.importWorkspace(
                from: config, modelContext: modelContext, capabilityTrust: .validate(.live())
            )
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "App", fields: [
                "operation": "import_config",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    /// A checkout that worktree cleanup is removing can't become a workspace
    /// root. The import is refused before anything is replaced and can be
    /// retried once cleanup finishes.
    private func refusesRoot(_ reserved: String?, operation: String) -> Bool {
        guard let reserved else { return false }
        AppLogger.audit(.workspaceRecoveryFailed, category: "App", fields: [
            "operation": operation,
            "reason": "workspace_root_being_removed",
            "path": reserved
        ], level: .warning)
        return true
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
        if refusesRoot(WorkspaceConfigManager.reservedRoot(among: [url.path]), operation: "import_folder") { return nil }
        if let existing = existingWorkspaces.first(where: { $0.name == name || $0.primaryPath == url.path }) {
            let action = askDuplicateAction(name, existing.tasks.count)
            if action != .skip,
               refusesRoot(WorkspaceConfigManager.reservedRoot(among: [url.path]), operation: "import_folder") {
                return nil
            }
            switch action {
            case .skip:
                return nil
            case .replace:
                // Exported only once its runs are cancelled, so the trusted
                // import recreates them stopped, never running or admissible.
                var exportedConfig: WorkspaceConfigManager.WorkspaceConfig?
                return replaceWorkspace(existing, replacementPath: url.path, afterCancellation: {
                    exportedConfig = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext)
                }) {
                    guard var config = exportedConfig else { return insertWorkspaceFromFolder(name: name, path: url.path) }
                    config.name = name
                    config.primaryPath = url.path
                    return WorkspaceConfigManager.importWorkspace(
                        from: config, modelContext: modelContext,
                        scheduleTrustPolicy: .preserveEnabledState, taskRecoveryTrustPolicy: .trustedLocalRecovery,
                        capabilityTrust: .preserveRecordedState
                    )
                }
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

@MainActor
struct ExecutionMutationSnapshot {
    let state: TaskStateMachine.Snapshot
    let updatedAt: Date
    let unreadAt: Date?
    let tokensUsed: Int
    let costUSD: Double
    let runtimePermissionOpenRequestsJSON: String?
    let runtimePermissionGrantsJSON: String?
    let eventIDs: Set<UUID>

    init(_ task: AgentTask) {
        state = TaskStateMachine.snapshot(task)
        updatedAt = task.updatedAt
        unreadAt = task.unreadAt
        tokensUsed = task.tokensUsed
        costUSD = task.costUSD
        runtimePermissionOpenRequestsJSON = task.runtimePermissionOpenRequestsJSON
        runtimePermissionGrantsJSON = task.runtimePermissionGrantsJSON
        eventIDs = Set(task.events.map(\.id))
    }

    func restore(_ task: AgentTask, in modelContext: ModelContext) {
        TaskStateMachine.restoreExecutionSubmissionFailure(
            task,
            snapshot: state,
            modelContext: modelContext,
            at: updatedAt
        )
        task.updatedAt = updatedAt
        task.unreadAt = unreadAt
        task.tokensUsed = tokensUsed
        task.costUSD = costUSD
        task.runtimePermissionOpenRequestsJSON = runtimePermissionOpenRequestsJSON
        task.runtimePermissionGrantsJSON = runtimePermissionGrantsJSON
        for event in task.events where !eventIDs.contains(event.id) {
            modelContext.delete(event)
        }
    }
}
