import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@Observable
final class TaskQueue {
    let poolSize: Int
    private let workerFactory: @MainActor () -> AgentRuntimeWorker
    private let persistQueueCancellation: @MainActor (ModelContext) -> Bool
    private(set) var workers: [AgentRuntimeWorker]
    private(set) var isProcessing = false
    private(set) var isProcessingScheduled = false
    private(set) var isStopping = false
    private var processingScheduleGeneration = 0
    private let requestTaskRegistry: ExecutionRequestTaskRegistry
    /// Track which worker is running which task (by task ID)
    private(set) var taskWorkerMap: [UUID: AgentRuntimeWorker] = [:]

    var activeTasks: Set<UUID> = []
    /// Track exclusive/shared resource ownership so write-capable work cannot
    /// mutate the same checkout concurrently.
    private(set) var activeResourceLocks: [TaskResourceLockClaim] = []
    private(set) var waitingResourceLocks: [UUID: TaskResourceLockClaim] = [:]

    private var dispatchedRequestIDs: Set<UUID> = []
    private var storeSession: TaskQueueStoreSession?
    @MainActor
    init(
        poolSize: Int = 3,
        workerFactory: @escaping @MainActor () -> AgentRuntimeWorker = { AgentRuntimeWorker() },
        persistQueueCancellation: @escaping @MainActor (ModelContext) -> Bool = TaskQueueCancellationService.persist
    ) {
        self.poolSize = poolSize
        self.workerFactory = workerFactory
        self.persistQueueCancellation = persistQueueCancellation
        self.workers = (0..<poolSize).map { _ in workerFactory() }
        self.requestTaskRegistry = ExecutionRequestTaskRegistry()
    }
    /// Number of currently busy workers
    var activeCount: Int {
        workers.filter(\.isRunning).count
    }

    var hasActiveUpdateBlockingWork: Bool {
        AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: hasProcessingLoop || isStopping,
            activeWorkerCount: activeCount,
            activeTaskCount: activeTasks.count,
            runningTaskCount: 0
        )
    }

    /// Whether any worker is available
    var hasAvailableWorker: Bool {
        workers.contains { !$0.isRunning }
    }

    var hasProcessingLoop: Bool {
        isProcessing || isProcessingScheduled
    }

    var hasBoundStoreSession: Bool { storeSession != nil }
    @MainActor var ownedCoroutineCount: Int { requestTaskRegistry.ownedTaskCount }
    @MainActor var pendingCompletionHandleCount: Int { requestTaskRegistry.promisedCompletionCount }

    /// Restarts waiting turns after startup recovery has reconciled stale
    /// process-local worker/lock ownership. Call only after runtime settings
    /// have been applied; each replay still passes through normal FIFO and
    /// resource-lock admission.
    @MainActor
    func replayRecoveredTurns(modelContext: ModelContext) {
        guard let storeSession = bindStoreSession(to: modelContext) else { return }
        let modelContext = storeSession.modelContext
        let requests: [TaskTurnRequest]
        do {
            requests = try TaskTurnRequestRepository.allActiveRequests(
                in: modelContext,
                sortBy: [SortDescriptor(\.submittedAt), SortDescriptor(\.sequence)]
            )
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "replay_recovered_turns_fetch",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return
        }
        guard !requests.isEmpty else { return }

        // Resolve every owning task in one fetch rather than per request —
        // the scalar `taskID` back-reference has no relationship to join on.
        let taskIDs = Array(Set(requests.map(\.taskID)))
        let tasksByID = Dictionary(
            ((try? modelContext.fetch(
                FetchDescriptor<AgentTask>(predicate: #Predicate { taskIDs.contains($0.id) })
            )) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var hasReplayableRequest = false
        for request in requests {
            guard let task = tasksByID[request.taskID] else {
                _ = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .failed,
                    terminalReason: "task_missing"
                )
                do {
                    try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                        workspace: nil,
                        modelContext: modelContext,
                        taskID: request.taskID,
                        auditFields: ["operation": "terminalize_orphan_execution_request"]
                    )
                } catch {
                    AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                        "operation": "terminalize_orphan_execution_request",
                        "request_id": request.id.uuidString
                    ], level: .error)
                }
                continue
            }
            guard task.events.contains(where: { $0.id == request.messageEventID }) else {
                failPersistedTurn(request, reason: "source_event_missing", modelContext: modelContext)
                continue
            }
            hasReplayableRequest = true
        }
        // Durable requests are already the replay authority. One queue wake is
        // sufficient; per-request Tasks would only capture SwiftData models
        // across an unnecessary suspension and complicate shutdown ownership.
        if hasReplayableRequest {
            _ = processQueueIfIdle(modelContext: storeSession.modelContext)
        }
    }

    @MainActor
    private func bindStoreSession(to modelContext: ModelContext) -> TaskQueueStoreSession? {
        if let storeSession {
            guard storeSession.matches(modelContext) else {
                AppLogger.audit(.workerBlocked, category: "Queue", fields: [
                    "reason": "different_store_context_while_queue_bound"
                ], level: .error)
                return nil
            }
            return storeSession
        }
        let session = TaskQueueStoreSession(modelContext: modelContext)
        storeSession = session
        return session
    }

    @MainActor
    private func startProcessing(storeSession: TaskQueueStoreSession) -> Task<Void, Never>? {
        guard !hasProcessingLoop, !isStopping else { return nil }

        isProcessingScheduled = true
        processingScheduleGeneration += 1
        let generation = processingScheduleGeneration
        let processingID = UUID()
        let processingTask = Task { @MainActor [storeSession] in
            defer { self.requestTaskRegistry.finishProcessing(id: processingID) }
            guard self.isProcessingScheduled,
                  self.processingScheduleGeneration == generation else {
                return
            }
            self.isProcessingScheduled = false
            storeSession.repairLegacyRequestsIfNeeded()
            await self.processQueueLoop(storeSession: storeSession)
        }
        requestTaskRegistry.registerProcessing(processingTask, id: processingID)
        return processingTask
    }

    /// Registers queue-adjacent lifecycle work that uses the same persistence
    /// session (for example post-run workflow resumption). Awaited shutdown
    /// cancels and drains these tasks together with processing and dispatch.
    @discardableResult
    @MainActor
    func registerLifecycleTask(
        modelContext: ModelContext,
        operation: @escaping @MainActor (ModelContext) async -> Void
    ) -> Task<Void, Never> {
        guard !isStopping, let storeSession = bindStoreSession(to: modelContext) else {
            return Task {}
        }
        let lifecycleID = UUID()
        let lifecycleTask = Task { @MainActor [storeSession] in
            defer { self.requestTaskRegistry.finishLifecycle(id: lifecycleID) }
            await operation(storeSession.modelContext)
        }
        requestTaskRegistry.registerLifecycle(lifecycleTask, id: lifecycleID)
        return lifecycleTask
    }

    @discardableResult
    @MainActor
    func processQueueIfIdle(modelContext: ModelContext) -> Bool {
        guard let storeSession = bindStoreSession(to: modelContext) else { return false }
        return startProcessing(storeSession: storeSession) != nil
    }

    @discardableResult
    @MainActor
    func signalExecutionRequest(
        id requestID: UUID,
        task: AgentTask,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default
    ) -> Task<Void, Never> {
        guard !isStopping,
              let storeSession = bindStoreSession(to: modelContext),
              storeSession.matches(modelContext) else {
            return Task {}
        }
        guard let request = try? TaskTurnRequestRepository.request(id: requestID, in: modelContext),
              request.taskID == task.id,
              request.state.isActive else {
            return Task {}
        }
        guard task.events.contains(where: { $0.id == request.sourceEventID }) else {
            failPersistedTurn(request, reason: "source_event_missing", modelContext: modelContext)
            return Task {}
        }

        _ = processQueueIfIdle(modelContext: storeSession.modelContext)
        // A signal is not a reservation; durable work stays queued when busy.
        return requestTaskRegistry.completionHandle(requestID: request.id)
    }

    /// Get the first available (idle) worker, or nil if all busy
    private func nextAvailableWorker() -> AgentRuntimeWorker? {
        workers.first { !$0.isRunning }
    }

    /// Get the worker assigned to a specific task
    func worker(for task: AgentTask) -> AgentRuntimeWorker? {
        taskWorkerMap[task.id]
    }

    /// Apply settings to all workers in the pool
    func applySettings(
        claudePath: String?,
        copilotPath: String? = nil,
        copilotHome: String? = nil,
        providerSettings: AgentRuntimeProviderSettings? = nil,
        defaultRuntimeID: AgentRuntimeID = .claudeCode,
        timeoutSeconds: TimeInterval,
        validationModel: String,
        skipPermissions: Bool = false,
        defaultPolicyLevelRaw: String = AgentPolicyLevel.review.rawValue
    ) {
        let configuredPolicyLevel = AgentPolicyDefaults.effectiveLevel(
            workspace: nil,
            globalDefaultRaw: defaultPolicyLevelRaw,
            skipPermissions: skipPermissions
        )
        let resolvedProviderSettings: AgentRuntimeProviderSettings? = providerSettings.map { settings in
            var settings = settings
            if let path = claudePath, !path.isEmpty {
                settings.setExecutablePath(path, for: .claudeCode)
            }
            if let path = copilotPath, !path.isEmpty {
                settings.setExecutablePath(path, for: .copilotCLI)
            }
            if let home = copilotHome, !home.isEmpty {
                settings.setHomeDirectory(home, for: .copilotCLI)
            } else if settings.homeDirectory(for: .copilotCLI).isEmpty {
                settings.setHomeDirectory(CopilotCLIRuntime.channelHome(), for: .copilotCLI)
            }
            return settings
        }
        for worker in workers {
            if let resolvedProviderSettings {
                worker.setProviderSettings(resolvedProviderSettings)
            } else {
                if let path = claudePath, !path.isEmpty {
                    worker.claudePath = path
                }
                if let path = copilotPath, !path.isEmpty {
                    worker.copilotPath = path
                }
                if let home = copilotHome, !home.isEmpty {
                    worker.copilotHome = home
                }
            }
            worker.defaultRuntimeID = defaultRuntimeID
            worker.timeoutSeconds = timeoutSeconds
            worker.validationModel = validationModel
            worker.skipPermissions = skipPermissions
            worker.defaultAgentPolicyLevelRaw = configuredPolicyLevel.rawValue
            worker.permissionPolicy = skipPermissions
                ? .autonomous
                : ProviderPolicyModeResolver.permissionPolicy(
                    for: AgentPolicy.preset(configuredPolicyLevel),
                    runtime: defaultRuntimeID
                )
        }
    }

    /// Execute a single task on the next available worker
    @MainActor
    func executeTask(
        _ task: AgentTask,
        modelContext: ModelContext,
        executionRequestID: UUID? = nil,
        resourceAccess: TaskResourceAccessMode = .write,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async {
        let executionRequest = executionRequestID.flatMap {
            try? TaskTurnRequestRepository.request(id: $0, in: modelContext)
        }
        if let readOnlyReason = TaskForkPolicyService.readOnlyReason(for: task) {
            recordForkReadOnlyBlock(task, reason: readOnlyReason, modelContext: modelContext)
            if let executionRequest, executionRequest.state.isActive {
                failPersistedTurn(executionRequest, reason: "read_only_task", modelContext: modelContext)
            }
            return
        }

        guard hasAvailableWorker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        let requestedResources = resourceLockClaims(
            for: executionRequest,
            task: task,
            runMode: "task",
            fallbackAccess: resourceAccess
        )
        guard let resourceLease = await waitForResourceLocks(
            task: task,
            claims: requestedResources,
            modelContext: modelContext,
            shouldAbort: executionRequest.map { request in
                { request.isDeleted || !request.state.isActive }
            }
        ) else {
            return
        }
        defer {
            releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
        }

        guard let worker = nextAvailableWorker() else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy_after_resource_lock",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        if executionRequestID != nil {
            guard let executionRequest,
                  executionRequest.taskID == task.id,
                  transitionPersistedTurn(
                    executionRequest,
                    to: .admitted,
                    modelContext: modelContext
                  ).persisted else {
                return
            }
        }

        guard admitQueuedTaskToRuntime(task, modelContext: modelContext, mode: "task") else {
            if let executionRequest, executionRequest.state == .admitted {
                failPersistedTurn(executionRequest, reason: "task_not_queued", modelContext: modelContext)
            }
            return
        }

        guard prepareTaskFolder(task, modelContext: modelContext, mode: "task") else {
            if let executionRequest, executionRequest.state.isActive {
                failPersistedTurn(executionRequest, reason: "task_folder_create_failed", modelContext: modelContext)
            }
            return
        }

        activeTasks.insert(task.id)
        taskWorkerMap[task.id] = worker
        AppLogger.audit(.taskAssigned, category: "Queue", taskID: task.id, fields: [
            "worker_index": String(workerIndex(worker) + 1),
            "pool_size": String(poolSize)
        ])

        // Inject template hooks if present
        let hooksBackup = injectTemplateHooks(for: task)

        await worker.execute(
            task: task,
            modelContext: modelContext,
            existingStartEventID: nil,
            executionRequestID: executionRequest?.id,
            executionPolicy: executionPolicy,
            onEvent: onEvent
        )

        // Restore hooks
        restoreTemplateHooks(for: task, backup: hooksBackup)

        taskWorkerMap.removeValue(forKey: task.id)
        activeTasks.remove(task.id)
        if let executionRequest, executionRequest.state == .admitted {
            failPersistedTurn(executionRequest, reason: "runtime_not_started", modelContext: modelContext)
        }
        AppLogger.audit(.workerExited, category: "Queue", taskID: task.id, fields: [
            "worker_index": String(workerIndex(worker) + 1),
            "status": task.status.rawValue
        ])

        // Route schedule results based on resultMode
        if let scheduleID = task.originScheduleID, task.isTerminal {
            routeScheduleResult(task: task, scheduleID: scheduleID, modelContext: modelContext)
        }

        // Auto-run chained task if one was created
        if task.status == .completed, let ws = task.workspace {
            let taskID = task.id
            let chainedTask = ws.tasks.first { $0.chainedFromID == taskID && $0.status == .queued }
            if let chainedTask {
                AppLogger.audit(.taskChained, category: "Queue", taskID: chainedTask.id, fields: [
                    "source_task_id": taskID.uuidString
                ])
                processQueueIfIdle(modelContext: modelContext)
            }
        }
    }

    /// Route a completed schedule-spawned task's results based on the schedule's resultMode.
    @MainActor
    func routeScheduleResult(task: AgentTask, scheduleID: UUID, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<TaskSchedule>(
            predicate: #Predicate<TaskSchedule> { $0.id == scheduleID }
        )
        guard let schedule = try? modelContext.fetch(descriptor).first else { return }

        let lastRun = task.runs.sorted { $0.startedAt < $1.startedAt }.last
        let outputSummary = String((lastRun?.output ?? "No output").prefix(500))
        let statusStr = task.status.rawValue

        switch schedule.resultMode {
        case .sameThread:
            if let sourceTaskID = schedule.sourceTaskID {
                let sourceDescriptor = FetchDescriptor<AgentTask>(
                    predicate: #Predicate<AgentTask> { $0.id == sourceTaskID }
                )
                if let sourceTask = try? modelContext.fetch(sourceDescriptor).first {
                    mergeSameThreadScheduleResult(
                        from: task,
                        into: sourceTask,
                        schedule: schedule,
                        latestRun: lastRun,
                        modelContext: modelContext
                    )

                    if task.id != sourceTask.id {
                        for artifact in task.artifacts {
                            artifact.task = sourceTask
                        }
                        // Preserve the completed scheduled child as the hidden
                        // owner of its immutable request/source/run ledger.
                        // The source thread receives copied presentation data,
                        // but history identity is never rewritten or deleted.
                        task.isDone = true
                    }
                } else {
                    let event = TaskEvent(
                        task: task,
                        eventType: TaskEventTypes.System.info,
                        payload: "Original same-thread task was not found. This run stayed as an independent task."
                    )
                    modelContext.insert(event)
                }
            }
            schedule.appendRunResult(status: statusStr, summary: outputSummary, taskID: task.id)

        case .newTask:
            // Task already exists independently — nothing extra to do
            break

        case .scheduleLog:
            schedule.appendRunResult(status: statusStr, summary: outputSummary, taskID: task.id)
        }

        if let ws = schedule.workspace {
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: ws, modelContext: modelContext)
        }
    }

    @MainActor
    func mergeSameThreadScheduleResult(
        from scheduledTask: AgentTask,
        into sourceTask: AgentTask,
        schedule: TaskSchedule,
        latestRun: TaskRun?,
        modelContext: ModelContext
    ) {
        let sourceMessage = TaskEvent(
            task: sourceTask,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: Self.sameThreadSchedulePrompt(schedule: schedule, fallbackGoal: scheduledTask.goal)
        )
        sourceMessage.timestamp = latestRun?.startedAt ?? Date()
        TaskEventInsertionService.insert(sourceMessage, into: modelContext)

        if let latestRun {
            let copiedRun = TaskRun(task: sourceTask)
            copiedRun.status = latestRun.status
            copiedRun.startedAt = latestRun.startedAt
            copiedRun.completedAt = latestRun.completedAt
            copiedRun.tokensUsed = latestRun.tokensUsed
            copiedRun.inputTokens = latestRun.inputTokens
            copiedRun.outputTokens = latestRun.outputTokens
            copiedRun.exitCode = latestRun.exitCode
            copiedRun.output = latestRun.output
            copiedRun.costUSD = latestRun.costUSD
            copiedRun.fileChangesJSON = latestRun.fileChangesJSON
            copiedRun.stopReason = latestRun.stopReason
            modelContext.insert(copiedRun)

            sourceTask.tokensUsed += latestRun.tokensUsed
            sourceTask.costUSD += latestRun.costUSD
            sourceTask.completedAt = latestRun.completedAt
            sourceTask.updatedAt = latestRun.completedAt ?? Date()
        } else {
            let fallbackEvent = TaskEvent(
                task: sourceTask,
                type: "schedule.result",
                payload: "**\(schedule.name)** — \(Self.dateFormatter.string(from: Date()))\nStatus: \(scheduledTask.status.rawValue)\n\nNo output was captured."
            )
            modelContext.insert(fallbackEvent)
            sourceTask.updatedAt = Date()
        }

        TaskStateMachine.mirrorScheduleResultStatus(
            sourceTask: sourceTask,
            scheduledTask: scheduledTask,
            modelContext: modelContext,
            at: sourceTask.updatedAt
        )
        sourceTask.isDone = false
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private static func sameThreadSchedulePrompt(schedule: TaskSchedule, fallbackGoal: String) -> String {
        let trimmedGoal = schedule.effectiveGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmedGoal.isEmpty ? fallbackGoal : trimmedGoal
        return """
        Routine run: \(schedule.name)

        \(goal)
        """
    }

    /// Continue a session on the worker that originally ran the task
    @MainActor
    func continueSession(
        task: AgentTask,
        message: String,
        existingMessageEventID: UUID? = nil,
        turnRequestID: UUID? = nil,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        resourceAccess: TaskResourceAccessMode = .write,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async -> Bool {
        if let turnRequestID {
            return await continuePersistedTurn(
                task: task,
                requestID: turnRequestID,
                modelContext: modelContext,
                executionPolicy: executionPolicy,
                resourceAccess: resourceAccess,
                onEvent: onEvent
            )
        }
        return await continueLegacySession(
            task: task,
            message: message,
            existingMessageEventID: existingMessageEventID,
            modelContext: modelContext,
            executionPolicy: executionPolicy,
            resourceAccess: resourceAccess,
            onEvent: onEvent
        )
    }

    /// Legacy continuation entrypoint retained for approval/resume flows that
    /// are not user-authored conversation turns. New chat submissions must use
    /// `turnRequestID` so their accepted message is durable before admission.
    @MainActor
    private func continueLegacySession(
        task: AgentTask,
        message: String,
        existingMessageEventID: UUID? = nil,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        resourceAccess: TaskResourceAccessMode = .write,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async -> Bool {
        let lifecycle = ContinuationLaunchLifecycle(task: task)

        if let readOnlyReason = TaskForkPolicyService.readOnlyReason(for: task) {
            recordForkReadOnlyBlock(task, reason: readOnlyReason, modelContext: modelContext)
            return false
        }

        // Try to find the original worker, or use any available one
        guard taskWorkerMap[task.id] != nil || hasAvailableWorker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "no_worker_for_continue"
            ], level: .warning)
            recordContinuationAdmissionFailure(task, lifecycle: lifecycle, modelContext: modelContext)
            return false
        }

        let requestedResources = resourceLockClaims(
            for: nil,
            task: task,
            runMode: "continue",
            fallbackAccess: resourceAccess
        )
        guard let resourceLease = await waitForResourceLocks(
            task: task,
            claims: requestedResources,
            modelContext: modelContext
        ) else {
            recordContinuationAdmissionFailure(task, lifecycle: lifecycle, modelContext: modelContext)
            return false
        }
        defer {
            releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
        }

        guard let worker = taskWorkerMap[task.id] ?? nextAvailableWorker() else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "no_worker_for_continue_after_resource_lock"
            ], level: .warning)
            recordContinuationAdmissionFailure(task, lifecycle: lifecycle, modelContext: modelContext)
            return false
        }

        guard prepareTaskFolder(task, modelContext: modelContext, mode: "continue") else {
            recordContinuationAdmissionFailure(task, lifecycle: lifecycle, modelContext: modelContext)
            return false
        }

        markContinuationLaunchAdmitted(task, modelContext: modelContext)
        taskWorkerMap[task.id] = worker
        await worker.continueSession(
            task: task,
            message: message,
            existingMessageEventID: existingMessageEventID,
            turnRequestID: nil,
            modelContext: modelContext,
            executionPolicy: executionPolicy,
            onEvent: onEvent
        )
        taskWorkerMap.removeValue(forKey: task.id)
        return true
    }

    /// Admits one already-persisted user turn. The request is FIFO within its
    /// task and records every wait state before yielding for a worker or shared
    /// workspace resource. This is intentionally separate from the legacy
    /// continuation path: a caller cannot accidentally recreate the old
    /// in-memory message window by passing a raw string.
    @MainActor
    private func continuePersistedTurn(
        task: AgentTask,
        requestID: UUID,
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy,
        resourceAccess: TaskResourceAccessMode,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async -> Bool {
        guard let request = try? TaskTurnRequestRepository.request(id: requestID, in: modelContext),
              request.taskID == task.id,
              request.state.isActive,
              let sourceEvent = task.events.first(where: { $0.id == request.sourceEventID }) else {
            return false
        }
        let message = ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent)?.message
            ?? sourceEvent.payload

        if let readOnlyReason = TaskForkPolicyService.readOnlyReason(for: task) {
            recordForkReadOnlyBlock(task, reason: readOnlyReason, modelContext: modelContext)
            failPersistedTurn(request, reason: "read_only_task", modelContext: modelContext)
            return false
        }

        // `isDeleted` guards every wake-up: task deletion cancels active
        // requests and then removes their rows, so a coroutine sleeping in a
        // poll must not touch (or resurrect) a deleted model on resume.
        // The generation check makes Stop Queue authoritative: cancelAll()
        // bumps it, so a parked admission loop terminalizes instead of
        // grabbing the just-freed worker and starting provider work the user
        // asked to stop.
        let entryAdmissionGeneration = turnAdmissionGeneration
        while !Task.isCancelled && !request.isDeleted && request.state.isActive
            && turnAdmissionGeneration == entryAdmissionGeneration {
            guard isEarliestActiveTurn(request, for: task, modelContext: modelContext) else {
                _ = transitionPersistedTurn(
                    request,
                    to: .waitingForWorker,
                    blockerSummary: "Waiting for an earlier message in this task.",
                    modelContext: modelContext
                )
                await waitForTurnAdmissionSignal(taskID: task.id)
                continue
            }

            // A task runs on at most one worker at a time. While this task's
            // current run holds its mapped worker (e.g. a follow-up sent
            // while the initial run is still executing with shared read-only
            // resource access), another idle worker would make
            // `hasAvailableWorker` true and the shared lock acquirable, but
            // selecting the busy mapped worker below just makes
            // `executeRuntimeSession` reject on `isRunning` and fail the
            // saved turn as `runtime_not_started`. Wait for the run instead.
            guard !activeTasks.contains(task.id) else {
                _ = transitionPersistedTurn(
                    request,
                    to: .waitingForWorker,
                    blockerSummary: "Waiting for the current run in this task to finish.",
                    modelContext: modelContext
                )
                await waitForTurnAdmissionSignal(taskID: task.id)
                continue
            }

            guard hasAvailableWorker else {
                _ = transitionPersistedTurn(
                    request,
                    to: .waitingForWorker,
                    blockerSummary: "Waiting for an available worker.",
                    modelContext: modelContext
                )
                await waitForTurnAdmissionSignal(taskID: task.id)
                continue
            }

            let pendingClaims = resourceLockClaims(
                for: request,
                task: task,
                runMode: "continue",
                fallbackAccess: resourceAccess
            )
            let blockingTaskID = TaskExecutionResourceBroker.firstConflict(
                requested: pendingClaims,
                active: activeResourceLocks
            )?.holder.taskID
            _ = transitionPersistedTurn(
                request,
                to: .waitingForResource,
                blockingTaskID: blockingTaskID,
                blockerSummary: blockingTaskID == nil ? nil : TaskExecutionResourceBroker.blockerSummary(
                    requested: pendingClaims,
                    active: activeResourceLocks
                ),
                modelContext: modelContext
            )
            guard let resourceLease = await waitForResourceLocks(
                task: task,
                claims: pendingClaims,
                modelContext: modelContext,
                shouldAbort: { request.isDeleted || !request.state.isActive }
            ) else {
                if !request.isDeleted, request.state.isActive {
                    _ = transitionPersistedTurn(
                        request,
                        to: .cancelled,
                        terminalReason: "admission_cancelled",
                        modelContext: modelContext
                    )
                }
                return false
            }

            guard !request.isDeleted, request.state.isActive,
                  turnAdmissionGeneration == entryAdmissionGeneration else {
                releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
                // The post-loop tail terminalizes a still-active request
                // (queue stopped mid-lock-wait) and no-ops a terminal one.
                break
            }
            // Re-check after the lock wait: the task could have started
            // running (occupying its mapped worker) while this coroutine was
            // suspended. A busy mapped worker must never be selected.
            guard !activeTasks.contains(task.id) else {
                releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
                _ = transitionPersistedTurn(
                    request,
                    to: .waitingForWorker,
                    blockerSummary: "Waiting for the current run in this task to finish.",
                    modelContext: modelContext
                )
                await waitForTurnAdmissionSignal(taskID: task.id)
                continue
            }
            guard let worker = taskWorkerMap[task.id] ?? nextAvailableWorker() else {
                releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
                _ = transitionPersistedTurn(
                    request,
                    to: .waitingForWorker,
                    blockerSummary: "Worker became unavailable during workspace admission.",
                    modelContext: modelContext
                )
                continue
            }
            guard prepareTaskFolder(task, modelContext: modelContext, mode: "continue") else {
                releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
                failPersistedTurn(request, reason: "task_folder_create_failed", modelContext: modelContext)
                return false
            }

            // The admitted state must be durable BEFORE the provider can
            // mutate the workspace: if this save is lost, a restart still
            // sees a waiting request and replays the same user turn,
            // duplicating whatever the runtime already did. On save failure
            // fail the turn in memory (best effort — the disk row stays
            // waiting and replays after restart) and do not launch.
            guard transitionPersistedTurn(request, to: .admitted, modelContext: modelContext).persisted else {
                releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
                failPersistedTurn(request, reason: "admission_persist_failed", modelContext: modelContext)
                return false
            }
            taskWorkerMap[task.id] = worker
            activeTasks.insert(task.id)
            // Promote the task to .running before handing off, exactly like the
            // legacy continuation path (markContinuationLaunchAdmitted). The
            // worker gates run creation on markRuntimeSessionStarted, whose
            // allowedFrom is [.running]; a follow-up to a completed/failed/
            // cancelled task — the primary durable-turn case — leaves the task
            // terminal, so without this the worker rejects and the turn is
            // admitted but never executed.
            let launchLifecycle = ContinuationLaunchLifecycle(task: task)
            markContinuationLaunchAdmitted(task, modelContext: modelContext)
            await worker.continueSession(
                task: task,
                message: message,
                existingMessageEventID: request.messageEventID,
                turnRequestID: request.id,
                modelContext: modelContext,
                executionPolicy: executionPolicy,
                onEvent: onEvent
            )
            taskWorkerMap.removeValue(forKey: task.id)
            activeTasks.remove(task.id)
            releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)

            // The task (and its request rows) can be deleted while the worker
            // ran; the deleted model must not be transitioned or reported on.
            guard !request.isDeleted else { return false }
            // A worker can reject before it constructs a TaskRun (for example,
            // when a stale task was no longer admissible). Runtime-created runs
            // finalize their request in AgentRuntimeWorker's defer.
            if request.state == .admitted {
                // The worker never created a run, so the optimistic .running
                // promotion above must be reverted or the task strands as
                // running forever.
                recordContinuationAdmissionFailure(task, lifecycle: launchLifecycle, modelContext: modelContext)
                failPersistedTurn(request, reason: "runtime_not_started", modelContext: modelContext)
                return false
            }
            return request.state == .completed
        }

        if !request.isDeleted, request.state.isActive {
            _ = transitionPersistedTurn(
                request,
                to: .cancelled,
                terminalReason: "admission_cancelled",
                modelContext: modelContext
            )
        }
        return false
    }

    @MainActor
    private func isEarliestActiveTurn(
        _ request: TaskTurnRequest,
        for task: AgentTask,
        modelContext: ModelContext
    ) -> Bool {
        guard let active = try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext) else {
            return false
        }
        return active.first?.id == request.id
    }

    @MainActor
    private func failPersistedTurn(
        _ request: TaskTurnRequest,
        reason: String,
        modelContext: ModelContext
    ) {
        _ = transitionPersistedTurn(
            request,
            to: .failed,
            terminalReason: reason,
            modelContext: modelContext
        )
    }

    /// A turn transition plus whether it actually reached disk. `persisted`
    /// is true for no-op transitions (nothing needed saving); admission is
    /// the one boundary that must check it before crossing into the provider.
    private struct PersistedTurnTransition {
        let transition: TaskTurnRequestStateMachine.TransitionResult
        let persisted: Bool
    }

    @MainActor
    @discardableResult
    private func transitionPersistedTurn(
        _ request: TaskTurnRequest,
        to state: TaskTurnRequestState,
        runID: UUID? = nil,
        blockingTaskID: UUID? = nil,
        blockerSummary: String? = nil,
        terminalReason: String? = nil,
        modelContext: ModelContext
    ) -> PersistedTurnTransition {
        let result = TaskTurnRequestStateMachine.transition(
            request,
            to: state,
            runID: runID,
            blockingTaskID: blockingTaskID,
            blockerSummary: blockerSummary,
            terminalReason: terminalReason
        )
        guard result.changed else {
            return PersistedTurnTransition(transition: result, persisted: true)
        }
        // A changed transition can make the next same-task turn the earliest
        // active request — wake its parked admission loop immediately.
        wakeTurnAdmissionWaiters(taskID: request.taskID)
        let taskID = request.taskID
        let persisted: Bool
        if state.isTerminal {
            let workspace = (try? modelContext.fetch(
                FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
            ))?.first?.workspace
            persisted = WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: workspace,
                modelContext: modelContext,
                taskID: taskID,
                auditFields: ["operation": "turn_request_\(state.rawValue)"]
            )
        } else {
            // Waiting and admission transitions must survive an app quit, but
            // should not race the later terminal workspace-mirror export.
            persisted = WorkspacePersistenceCoordinator.saveWithoutAutoExport(
                modelContext: modelContext,
                taskID: taskID,
                auditFields: ["operation": "turn_request_\(state.rawValue)"]
            )
        }
        return PersistedTurnTransition(transition: result, persisted: persisted)
    }

    /// Parked admission loops, keyed by task id. Everything here is
    /// MainActor-serialized: registration, wake, and the fallback tick all
    /// run on the actor, so a continuation is resumed exactly once (the dict
    /// removal is the claim).
    private var turnAdmissionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Bumped by `cancelAll()`. Admission loops capture the value at entry
    /// and exit (terminalizing their request) once it changes, so Stop Queue
    /// also stops durable-turn admissions that were parked waiting.
    private var turnAdmissionGeneration = 0

    /// Parks one admission-loop iteration until queue state plausibly changed.
    /// Waking is signal-driven — a same-task turn transition, a turn
    /// cancellation, or any worker/resource-lock release — instead of a
    /// per-request 100 ms poll, so N waiting turns no longer generate N
    /// repeating main-actor fetches. A 500 ms fallback tick bounds staleness
    /// for changes with no signal (e.g. pool resize) and honors cancellation.
    private func waitForTurnAdmissionSignal(taskID: UUID) async {
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            turnAdmissionWaiters[taskID, default: [:]][waiterID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.resumeTurnAdmissionWaiter(taskID: taskID, waiterID: waiterID)
            }
        }
    }

    private func resumeTurnAdmissionWaiter(taskID: UUID, waiterID: UUID) {
        guard let continuation = turnAdmissionWaiters[taskID]?.removeValue(forKey: waiterID) else { return }
        if turnAdmissionWaiters[taskID]?.isEmpty == true {
            turnAdmissionWaiters.removeValue(forKey: taskID)
        }
        continuation.resume()
    }

    private func wakeTurnAdmissionWaiters(taskID: UUID) {
        guard let waiters = turnAdmissionWaiters.removeValue(forKey: taskID) else { return }
        for continuation in waiters.values { continuation.resume() }
    }

    /// Worker and resource-lock availability are queue-global, so releases
    /// wake every parked admission loop, not just the releasing task's.
    private func wakeAllTurnAdmissionWaiters() {
        let all = turnAdmissionWaiters
        turnAdmissionWaiters.removeAll()
        for waiters in all.values {
            for continuation in waiters.values { continuation.resume() }
        }
    }

    private struct ContinuationLaunchLifecycle {
        let previousStatus: TaskStatus
        let previousCompletedAt: Date?

        init(task: AgentTask) {
            previousStatus = task.status
            previousCompletedAt = task.completedAt
        }
    }

    @MainActor
    private func markContinuationLaunchAdmitted(_ task: AgentTask, modelContext: ModelContext) {
        TaskStateMachine.admitContinuationToRuntime(task, modelContext: modelContext)
    }

    @MainActor
    private func recordContinuationAdmissionFailure(
        _ task: AgentTask,
        lifecycle: ContinuationLaunchLifecycle,
        modelContext: ModelContext
    ) {
        guard task.status == .running || task.status == lifecycle.previousStatus else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "continuation_not_admitted",
                "preserved_status": task.status.rawValue
            ], level: .debug)
            return
        }

        TaskStateMachine.restoreContinuationAdmissionFailure(
            task,
            snapshot: TaskStateMachine.Snapshot(status: lifecycle.previousStatus, completedAt: lifecycle.previousCompletedAt),
            modelContext: modelContext
        )
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.error,
            payload: "Couldn't continue this task — it couldn't be started right now. Try again in a moment."
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    /// Execute a user-approved plan on the next available worker.
    @MainActor
    func executeApprovedPlan(
        task: AgentTask,
        plan: TaskPlanPayload,
        mode: TaskPlanExecutionMode = .fullPlan,
        modelContext: ModelContext,
        executionRequestID: UUID? = nil,
        resourceAccess: TaskResourceAccessMode = .write,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async {
        let executionRequest = executionRequestID.flatMap {
            try? TaskTurnRequestRepository.request(id: $0, in: modelContext)
        }
        if let readOnlyReason = TaskForkPolicyService.readOnlyReason(for: task) {
            recordForkReadOnlyBlock(task, reason: readOnlyReason, modelContext: modelContext)
            if let executionRequest, executionRequest.state.isActive {
                failPersistedTurn(executionRequest, reason: "read_only_task", modelContext: modelContext)
            }
            return
        }

        guard hasAvailableWorker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy",
                "mode": "approved_plan",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        let requestedResources = resourceLockClaims(
            for: executionRequest,
            task: task,
            runMode: "approved_plan",
            fallbackAccess: resourceAccess
        )
        guard let resourceLease = await waitForResourceLocks(
            task: task,
            claims: requestedResources,
            modelContext: modelContext,
            shouldAbort: executionRequest.map { request in
                { request.isDeleted || !request.state.isActive }
            }
        ) else {
            return
        }
        defer {
            releaseResourceLocks(resourceLease, task: task, modelContext: modelContext)
        }

        guard let worker = nextAvailableWorker() else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy_after_resource_lock",
                "mode": "approved_plan",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        if executionRequestID != nil {
            guard let executionRequest,
                  executionRequest.taskID == task.id,
                  transitionPersistedTurn(
                    executionRequest,
                    to: .admitted,
                    modelContext: modelContext
                  ).persisted else {
                return
            }
        }

        guard admitQueuedTaskToRuntime(task, modelContext: modelContext, mode: "approved_plan") else {
            if let executionRequest, executionRequest.state == .admitted {
                failPersistedTurn(executionRequest, reason: "task_not_queued", modelContext: modelContext)
            }
            return
        }

        guard prepareTaskFolder(task, modelContext: modelContext, mode: "approved_plan") else {
            if let executionRequest, executionRequest.state.isActive {
                failPersistedTurn(executionRequest, reason: "task_folder_create_failed", modelContext: modelContext)
            }
            return
        }

        activeTasks.insert(task.id)
        taskWorkerMap[task.id] = worker
        AppLogger.audit(.taskAssigned, category: "Queue", taskID: task.id, fields: [
            "worker_index": String(workerIndex(worker) + 1),
            "pool_size": String(poolSize),
            "mode": "approved_plan",
            "plan_execution_mode": mode.rawValue
        ])

        await worker.executeApprovedPlan(
            task: task,
            plan: plan,
            mode: mode,
            existingStartEventID: nil,
            executionRequestID: executionRequest?.id,
            modelContext: modelContext,
            executionPolicy: executionPolicy,
            onEvent: onEvent
        )

        taskWorkerMap.removeValue(forKey: task.id)
        activeTasks.remove(task.id)
        if let executionRequest, executionRequest.state == .admitted {
            let terminalState: TaskTurnRequestState = task.status == .completed ? .completed : .failed
            _ = transitionPersistedTurn(
                executionRequest,
                to: terminalState,
                terminalReason: terminalState == .failed ? "runtime_not_started" : nil,
                modelContext: modelContext
            )
        }
        AppLogger.audit(.workerExited, category: "Queue", taskID: task.id, fields: [
            "worker_index": String(workerIndex(worker) + 1),
            "status": task.status.rawValue,
            "mode": "approved_plan",
            "plan_execution_mode": mode.rawValue
        ])
    }

    @MainActor
    private func admitQueuedTaskToRuntime(
        _ task: AgentTask,
        modelContext: ModelContext,
        mode: String
    ) -> Bool {
        let result = TaskStateMachine.admitQueuedTaskToRuntime(task, modelContext: modelContext)
        guard result.rejection == nil else {
            recordQueueAdmissionRejection(task, result: result, modelContext: modelContext, mode: mode)
            return false
        }
        return true
    }

    @MainActor
    private func recordQueueAdmissionRejection(
        _ task: AgentTask,
        result: TaskStateMachine.TransitionResult,
        modelContext: ModelContext,
        mode: String
    ) {
        AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
            "reason": "queue_admission_rejected",
            "mode": mode,
            "from": result.from.rawValue,
            "to": result.to.rawValue
        ], level: .warning)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.error,
            payload: "This task could not be admitted to runtime because it is no longer queued. Current status: \(result.from.rawValue)."
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: [
                "operation": "queue_admission_rejected",
                "mode": mode,
                "status": result.from.rawValue
            ]
        )
    }

    @MainActor
    private func prepareTaskFolder(_ task: AgentTask, modelContext: ModelContext, mode: String) -> Bool {
        do {
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            AppLogger.audit(.taskStarted, category: "Queue", taskID: task.id, fields: [
                "event": "task_folder_prepared",
                "mode": mode,
                "folder_available": String(!folder.isEmpty)
            ], level: .debug)
            return true
        } catch {
            AppLogger.audit(.taskFailed, category: "Queue", taskID: task.id, fields: [
                "reason": "task_folder_create_failed",
                "mode": mode,
                "error_type": String(describing: type(of: error))
            ], level: .error)
            let now = Date()
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext, at: now)
            modelContext.insert(TaskEvent(
                task: task,
                type: "error",
                payload: "ASTRA could not create this task's output folder before launching the agent: \(error.localizedDescription)"
            ))
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "task_folder_create_failed"]
            )
            return false
        }
    }

    @MainActor
    func processQueue(modelContext: ModelContext) async {
        guard let storeSession = bindStoreSession(to: modelContext),
              let processingTask = startProcessing(storeSession: storeSession) else {
            return
        }
        await processingTask.value
    }

    @MainActor
    private func processQueueLoop(storeSession: TaskQueueStoreSession) async {
        let modelContext = storeSession.modelContext
        guard !isProcessing else {
            AppLogger.audit(.workerBlocked, category: "Queue", fields: [
                "reason": "queue_already_processing"
            ], level: .warning)
            return
        }
        isProcessingScheduled = false
        isProcessing = true
        dispatchedRequestIDs.removeAll()

        while !Task.isCancelled && isProcessing {
            guard let projection = try? ExecutionRequestAdmissionScheduler.projection(in: modelContext) else {
                AppLogger.audit(.taskFailed, category: "Queue", fields: [
                    "reason": "execution_request_projection_failed"
                ], level: .error)
                break
            }
            for orphan in projection.missingTaskRequests {
                failPersistedTurn(orphan, reason: "task_missing", modelContext: modelContext)
                requestTaskRegistry.complete(requestID: orphan.id)
            }
            if !projection.missingTaskRequests.isEmpty { continue }

            let snapshotFields = ExecutionRequestQueueSnapshot.fields(projection: projection)
            guard !projection.ordered.isEmpty else {
                if dispatchedRequestIDs.isEmpty {
                    ExecutionRequestQueueSnapshot.logDrained(projection: projection, poolSize: poolSize, activeWorkerCount: activeCount)
                    break
                }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { break }
                continue
            }

            guard hasAvailableWorker else {
                for waiting in projection.ordered where !dispatchedRequestIDs.contains(waiting.request.id) {
                    _ = transitionPersistedTurn(
                        waiting.request,
                        to: .waitingForWorker,
                        blockerSummary: activeTasks.contains(waiting.task.id)
                            ? "Waiting for the current run in this task to finish."
                            : "Waiting for an available worker.",
                        modelContext: modelContext
                    )
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
                continue
            }

            // Global FIFO gives old work priority; filtering only unavailable
            // tasks/resources avoids head-of-line blocking across projects.
            guard let next = ExecutionRequestAdmissionScheduler.nextCandidate(
                from: projection,
                dispatchedRequestIDs: dispatchedRequestIDs,
                activeTaskIDs: activeTasks,
                resourceIsAvailable: { candidate in
                    TaskForkPolicyService.readOnlyReason(for: candidate.task) == nil
                        && canAdmitResourceClaims(
                            for: candidate,
                            in: projection,
                            dispatchedRequestIDs: dispatchedRequestIDs,
                            activeTaskIDs: activeTasks
                        )
                }
            ) else {
                var forkBlockedRequestIDs = Set<UUID>()
                for blocked in projection.ordered where
                    !dispatchedRequestIDs.contains(blocked.request.id)
                        && !activeTasks.contains(blocked.task.id) {
                    guard let blocker = TaskForkPolicyService.activeSharedWorktreeBlocker(for: blocked.task),
                          let reason = TaskForkPolicyService.readOnlyReason(for: blocked.task) else { continue }
                    forkBlockedRequestIDs.insert(blocked.request.id)
                    _ = transitionPersistedTurn(
                        blocked.request,
                        to: .waitingForResource,
                        blockingTaskID: blocker.id,
                        blockerSummary: reason,
                        modelContext: modelContext
                    )
                }
                let resourceBlocked = projection.ordered.filter {
                    !dispatchedRequestIDs.contains($0.request.id)
                        && !activeTasks.contains($0.task.id)
                        && !forkBlockedRequestIDs.contains($0.request.id)
                }
                for blocked in resourceBlocked {
                    let claims = resourceLockClaims(
                        for: blocked.request,
                        task: blocked.task,
                        runMode: "request"
                    )
                    guard let primary = TaskExecutionResourceBroker.firstConflict(
                        requested: claims,
                        active: activeResourceLocks
                    )?.requested ?? TaskExecutionResourceAdmissionPolicy.earlierCompetingClaim(
                        for: blocked,
                        claims: claims,
                        in: projection,
                        dispatchedRequestIDs: dispatchedRequestIDs,
                        activeTaskIDs: activeTasks
                    ) else { continue }
                    let wasAlreadyWaiting = waitingResourceLocks[blocked.task.id] != nil
                    waitingResourceLocks[blocked.task.id] = primary
                    let activeConflict = TaskExecutionResourceBroker.firstConflict(
                        requested: claims,
                        active: activeResourceLocks
                    )
                    _ = transitionPersistedTurn(
                        blocked.request,
                        to: .waitingForResource,
                        blockingTaskID: activeConflict?.holder.taskID,
                        blockerSummary: activeConflict == nil
                            ? "Waiting behind an earlier request for \(TaskExecutionResourceBroker.displayName(primary))."
                            : TaskExecutionResourceBroker.blockerSummary(
                                requested: claims,
                                active: activeResourceLocks
                            ),
                        modelContext: modelContext
                    )
                    if !wasAlreadyWaiting {
                        AppLogger.audit(.resourceLockWaiting, category: "Queue", taskID: blocked.task.id, fields: [
                            "resource_kind": primary.resourceKind.rawValue,
                            "resource_key": primary.resourceKey,
                            "access_mode": primary.accessMode.rawValue,
                            "run_mode": primary.runMode,
                            "reason": activeConflict == nil ? "earlier_request" : "active_holder"
                        ], level: .warning)
                    }
                }
                for blocked in projection.ordered where
                    !dispatchedRequestIDs.contains(blocked.request.id)
                        && activeTasks.contains(blocked.task.id) {
                    _ = transitionPersistedTurn(
                        blocked.request,
                        to: .waitingForWorker,
                        blockerSummary: "Waiting for the current run in this task to finish.",
                        modelContext: modelContext
                    )
                }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { break }
                continue
            }

            // Mark as dispatched BEFORE firing the Task to prevent double-dispatch
            dispatchedRequestIDs.insert(next.request.id)

            AppLogger.audit(.taskDequeued, category: "Queue", taskID: next.task.id, fields: snapshotFields.merging([
                "request_id": next.request.id.uuidString,
                "request_state": next.request.state.rawValue,
                "active_worker_count": String(activeCount),
                "pool_size": String(poolSize)
            ], uniquingKeysWith: { _, current in current }))

            let queue = self
            let requestID = next.request.id
            let taskID = next.task.id
            let dispatchTask = Task { @MainActor [storeSession] in
                defer {
                    queue.dispatchedRequestIDs.remove(requestID)
                    queue.requestTaskRegistry.finishDispatch(requestID: requestID)
                }
                await queue.executeQueuedRequest(
                    requestID: requestID,
                    taskID: taskID,
                    storeSession: storeSession
                )
            }
            requestTaskRegistry.registerDispatch(dispatchTask, requestID: requestID)

            // Brief yield to let the task start
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }

        // Wait for all remaining workers to finish
        while activeCount > 0 && !Task.isCancelled && isProcessing {
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { break }
        }

        dispatchedRequestIDs.removeAll()
        isProcessing = false
    }

    @MainActor
    private func executeQueuedRequest(
        requestID: UUID,
        taskID: UUID,
        storeSession: TaskQueueStoreSession
    ) async {
        let modelContext = storeSession.modelContext
        guard let request = try? TaskTurnRequestRepository.request(id: requestID, in: modelContext),
              request.state.isActive else {
            return
        }
        let tasks = try? modelContext.fetch(
            FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        )
        guard let task = tasks?.first, request.taskID == task.id else {
            failPersistedTurn(request, reason: "task_missing", modelContext: modelContext)
            return
        }
        let launchSnapshot = TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task)
        let resourceAccess = resourceAccess(for: request, task: task)
        guard let sourceEvent = task.events.first(where: { $0.id == request.sourceEventID }) else {
            failPersistedTurn(request, reason: "source_event_missing", modelContext: modelContext)
            return
        }
        let source = ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent)
        let requestExecutionPolicy = (source?.executionPolicyOverride?.executionPolicy ?? .default)
            .withLaunchSnapshot(launchSnapshot)
        if source?.launchMode == .continuation || request.kind == .followUp {
            _ = await continuePersistedTurn(
                task: task,
                requestID: request.id,
                modelContext: modelContext,
                executionPolicy: requestExecutionPolicy,
                resourceAccess: resourceAccess,
                onEvent: { _ in }
            )
            return
        }
        if source?.launchMode == .approvedPlan || request.kind == .planStep {
            guard let source,
                  let requestedPlanID = source.planID,
                  let plan = source.planSnapshot,
                  plan.planID == requestedPlanID,
                  let mode = source.planExecutionMode else {
                failPersistedTurn(request, reason: "plan_source_unavailable", modelContext: modelContext)
                TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
                WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                return
            }
            await executeApprovedPlan(
                task: task,
                plan: plan,
                mode: mode,
                modelContext: modelContext,
                executionRequestID: request.id,
                resourceAccess: resourceAccess,
                executionPolicy: requestExecutionPolicy
            )
            return
        }
        await executeTask(
            task,
            modelContext: modelContext,
            executionRequestID: request.id,
            resourceAccess: resourceAccess,
            executionPolicy: requestExecutionPolicy
        )
    }

    /// Cancel a specific task's worker
    @MainActor
    /// Turn requests reference their task by scalar id, so `modelContext
    /// .delete(task)` never cascades to them. Any queue-owned task deletion
    /// (e.g. a merged same-thread scheduled task) must cancel active requests
    /// first — a parked admission coroutine would otherwise wake after the
    /// resource lock is released and start provider work for a deleted task —
    /// and then remove the rows so they don't outlive the task as orphans.
    /// Mirrors `TaskLifecycleCoordinator.cancelAndRemoveTurnRequests`.
    func cancelAndRemoveTurnRequests(for task: AgentTask, modelContext: ModelContext) {
        cancel(task: task, modelContext: modelContext)
        if let requests = try? TaskTurnRequestRepository.requests(for: task, in: modelContext) {
            for request in requests {
                modelContext.delete(request)
            }
        }
    }

    /// Stop only the task's active run: cancel the worker and terminalize the
    /// run/task, but leave queued turn requests saved. The complement of
    /// `cancelTurnRequest` for the send-while-running dock — its "Stop run"
    /// promises queued messages survive, while `cancel(task:modelContext:)`
    /// terminalizes every active request.
    @MainActor
    func stopActiveRun(task: AgentTask, modelContext: ModelContext) {
        cancel(task: task, modelContext: nil)
        let summary = TaskRunLifecycleService.cancelTask(
            task,
            modelContext: modelContext,
            source: .userAction
        )
        AppLogger.audit(.taskCancelled, category: "Queue", taskID: task.id, fields: [
            "scope": "active_run",
            "running_runs_cancelled": String(summary.runsUpdated)
        ])
        TaskRunLifecycleService.persist(summary: summary, modelContext: modelContext)
    }

    @MainActor
    func cancel(task: AgentTask, modelContext: ModelContext? = nil) {
        if let worker = taskWorkerMap[task.id] {
            worker.cancel()
            taskWorkerMap.removeValue(forKey: task.id)
            AppLogger.audit(.taskCancelled, category: "Queue", taskID: task.id)
        }
        // The empty-array case must not fall through to the save below: a
        // cancel with nothing to cancel would still auto-export, resurrecting
        // workspace mirrors that a caller (e.g. deleteWorkspace) just removed.
        if let modelContext,
           let requests = try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext),
           !requests.isEmpty {
            for request in requests {
                _ = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .cancelled,
                    terminalReason: "cancelled_by_user"
                )
            }
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "cancel_turn_requests"]
            )
        }
        wakeTurnAdmissionWaiters(taskID: task.id)
    }

    /// Retract one saved-but-not-yet-admitted turn without touching the rest
    /// of the task. `cancel(task:)` is deliberately wider (worker + every
    /// active request); a waiting follow-up on a completed task must be
    /// cancellable without flipping that task's terminal status.
    ///
    /// Waiting states ONLY: a stale click can land after the request reached
    /// `.admitted`/`.running`, when a worker already owns it. Marking it
    /// cancelled then would not stop the provider, and the runtime finalizer
    /// cannot overwrite the terminal state — the turn would display as
    /// cancelled while still mutating the workspace. Post-admission stops go
    /// through the worker-cancelling paths instead.
    @MainActor
    func cancelTurnRequest(id: UUID, workspace: Workspace?, modelContext: ModelContext) {
        guard let request = try? TaskTurnRequestRepository.request(id: id, in: modelContext),
              request.state == .waitingForWorker || request.state == .waitingForResource else { return }
        let previousState = request.state
        let previousBlockingTaskID = request.blockingTaskID
        let previousBlockerSummary = request.blockerSummary
        let result = transitionPersistedTurn(
            request,
            to: .cancelled,
            terminalReason: "cancelled_by_user",
            modelContext: modelContext
        )
        guard result.persisted else {
            // Cancellation is not durable: a crash before a later successful
            // save would let startup recovery replay the message the user
            // just retracted. Revert in memory too, so the parked admission
            // coroutine (already woken by the failed transition above)
            // re-parks as still-waiting instead of treating this as
            // terminal — memory and disk both keep the pre-cancel state.
            Self.revertFailedCancellation(
                request,
                to: previousState,
                blockingTaskID: previousBlockingTaskID,
                blockerSummary: previousBlockerSummary
            )
            AppLogger.audit(.taskCancelled, category: "Queue", taskID: request.taskID, fields: [
                "scope": "turn_request",
                "request_id": request.id.uuidString,
                "result": "persist_failed"
            ], level: .error)
            return
        }
        requestTaskRegistry.complete(requestID: request.id)
        AppLogger.audit(.taskCancelled, category: "Queue", taskID: request.taskID, fields: [
            "scope": "turn_request",
            "request_id": request.id.uuidString
        ])
    }

    /// Atomically retracts every not-yet-admitted request before returning a
    /// queued task to editable draft state. Without this boundary the durable
    /// request can be replayed after the UI says the task is a draft.
    @MainActor
    func moveQueuedTaskToDraftForEditing(
        _ task: AgentTask,
        modelContext: ModelContext
    ) -> Bool {
        guard let requestIDs = QueuedTaskDraftTransitionService.transition(
            task,
            modelContext: modelContext
        ) else { return false }
        requestIDs.forEach { requestTaskRegistry.complete(requestID: $0) }
        return true
    }

    /// Reverts a request to its pre-cancellation snapshot after
    /// `cancelTurnRequest` fails to persist. `.cancelled -> .waitingForWorker`
    /// is the only path the state machine allows back out of `.cancelled`; a
    /// request that was `.waitingForResource` before the failed cancel can't
    /// take it, so this falls back to restoring the captured fields directly
    /// (still posting the same change notification the state machine would
    /// have) instead of leaving the request stuck `.cancelled` in memory with
    /// its blocker metadata wiped.
    @MainActor
    static func revertFailedCancellation(
        _ request: TaskTurnRequest,
        to previousState: TaskTurnRequestState,
        blockingTaskID: UUID?,
        blockerSummary: String?
    ) {
        let reverted = TaskTurnRequestStateMachine.transition(
            request,
            to: previousState,
            blockingTaskID: blockingTaskID,
            blockerSummary: blockerSummary
        )
        guard reverted.rejection != nil else { return }
        request.state = previousState
        request.blockingTaskID = blockingTaskID
        request.blockerSummary = blockerSummary
        request.terminalAt = nil
        request.terminalReason = nil
        TaskThreadChangeNotifier.post(taskID: request.taskID, source: "turn_request_\(previousState.rawValue)")
    }

    /// Cancel all running workers
    @MainActor
    @discardableResult
    func cancelAll() -> Bool {
        var durableRequestIDs = Set<UUID>()
        if let modelContext = storeSession?.modelContext {
            guard let requestIDs = TaskQueueCancellationService.cancelActiveRequests(
                in: modelContext,
                persist: { persistQueueCancellation(modelContext) }
            ) else { return false }
            durableRequestIDs.formUnion(requestIDs)
        }
        isStopping = true
        for worker in workers {
            worker.cancel()
        }
        taskWorkerMap.removeAll()
        activeTasks.removeAll()
        let cancelledDispatchIDs = dispatchedRequestIDs
        requestTaskRegistry.cancelOwnedTasks()
        dispatchedRequestIDs.removeAll()
        let waitingRequestIDs = requestTaskRegistry.waitingRequestIDs
        var completedRequestIDs = cancelledDispatchIDs
        for requestID in durableRequestIDs where completedRequestIDs.insert(requestID).inserted {
            requestTaskRegistry.complete(requestID: requestID)
        }
        for requestID in waitingRequestIDs where !completedRequestIDs.contains(requestID) {
            requestTaskRegistry.complete(requestID: requestID)
        }
        activeResourceLocks.removeAll()
        waitingResourceLocks.removeAll()
        isProcessingScheduled = false
        processingScheduleGeneration += 1
        isProcessing = false
        // Stop parked durable-turn admissions too: bump the generation so a
        // woken loop terminalizes instead of admitting into the workers and
        // locks this just cleared, then wake every waiter immediately.
        turnAdmissionGeneration += 1
        wakeAllTurnAdmissionWaiters()
        AppLogger.audit(.taskCancelled, category: "Queue", fields: [
            "scope": "all_workers"
        ])
        return true
    }

    /// Scene/test teardown boundary. `cancelAll()` synchronously revokes queue
    /// authority; this variant additionally waits until every task that had
    /// already received SwiftData objects has returned them, preventing those
    /// objects from outliving their ModelContext.
    @MainActor
    @discardableResult
    func cancelAllAndWait() async -> Bool {
        let drainingSession = storeSession
        let drain = requestTaskRegistry.drainSnapshot()
        guard cancelAll() else { return false }
        await drain.wait()
        if storeSession === drainingSession, !hasProcessingLoop {
            storeSession = nil
        }
        isStopping = false
        return true
    }

    /// Resize the worker pool at runtime (only adds/removes idle workers).
    @MainActor
    func resizePool(to newSize: Int) {
        guard newSize > 0 else { return }
        if newSize > workers.count {
            let toAdd = newSize - workers.count
            for _ in 0..<toAdd {
                workers.append(workerFactory())
            }
            AppLogger.audit(.taskStats, category: "Queue", fields: [
                "event": "pool_resized",
                "worker_count": String(workers.count)
            ])
        } else if newSize < workers.count {
            // Only remove idle workers from the end
            var removed = 0
            while workers.count > newSize {
                if let idx = workers.lastIndex(where: { !$0.isRunning }) {
                    let worker = workers[idx]
                    // Clean up any task mapping
                    taskWorkerMap = taskWorkerMap.filter { $0.value !== worker }
                    workers.remove(at: idx)
                    removed += 1
                } else {
                    break // All remaining workers are busy
                }
            }
            if removed > 0 {
                AppLogger.audit(.taskStats, category: "Queue", fields: [
                    "event": "pool_resized",
                    "worker_count": String(workers.count),
                    "removed_count": String(removed)
                ])
            }
        }
    }

    private func workerIndex(_ worker: AgentRuntimeWorker) -> Int { workers.firstIndex(where: { $0 === worker }) ?? 0 }

    // MARK: - Resource Locks

    @MainActor
    func resourceAccess(for task: AgentTask) -> TaskResourceAccessMode {
        TaskExecutionResourceClaimResolver.workspaceAccess(for: task) == .shared ? .readOnly : .write }

    @MainActor
    func resourceAccess(for request: TaskTurnRequest?, task: AgentTask) -> TaskResourceAccessMode {
        TaskExecutionResourceClaimResolver.workspaceClaim(for: request, task: task)?.access == .shared ? .readOnly : .write }

    @MainActor
    func resourceKey(for task: AgentTask) -> String {
        TaskExecutionResourceClaimResolver.workspaceClaim(for: nil, task: task)?.key ?? "task:\(task.id.uuidString)" }

    @MainActor
    func resourceKey(for request: TaskTurnRequest?, task: AgentTask) -> String {
        TaskExecutionResourceClaimResolver.workspaceClaim(for: request, task: task)?.key ?? resourceKey(for: task) }

    @MainActor
    func resourceLockClaims(
        for request: TaskTurnRequest?,
        task: AgentTask,
        runMode: String,
        fallbackAccess: TaskResourceAccessMode? = nil
    ) -> [TaskResourceLockClaim] {
        TaskExecutionResourceAdmissionPolicy.lockClaims(
            for: request,
            task: task,
            runMode: runMode,
            fallbackAccess: fallbackAccess
        )
    }

    @MainActor
    func canAcquireResourceLocks(_ claims: [TaskResourceLockClaim]) -> Bool {
        !claims.isEmpty && TaskExecutionResourceBroker.canAcquire(claims, active: activeResourceLocks)
    }

    @MainActor
    func canAdmitResourceClaims(
        for candidate: ExecutionRequestAdmissionScheduler.Candidate,
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>
    ) -> Bool {
        TaskExecutionResourceAdmissionPolicy.canAdmit(
            candidate,
            in: projection,
            dispatchedRequestIDs: dispatchedRequestIDs,
            activeTaskIDs: activeTaskIDs,
            activeClaims: activeResourceLocks
        )
    }

    @MainActor
    func canAcquireResourceLock(
        for task: AgentTask,
        resourceKey: String? = nil,
        accessMode: TaskResourceAccessMode
    ) -> Bool {
        canAcquireResourceLocks([
            TaskResourceLockClaim(
                taskID: task.id,
                resourceKey: resourceKey ?? self.resourceKey(for: task),
                accessMode: accessMode,
                runMode: "probe"
            )
        ])
    }

    @MainActor
    @discardableResult
    func acquireResourceLocksIfAvailable(
        _ claims: [TaskResourceLockClaim],
        task: AgentTask,
        modelContext: ModelContext? = nil
    ) -> [TaskResourceLockClaim]? {
        guard canAcquireResourceLocks(claims) else { return nil }
        activeResourceLocks.append(contentsOf: claims)
        waitingResourceLocks.removeValue(forKey: task.id)
        for claim in claims {
            recordResourceLockEvent(
                type: TaskResourceLockEventTypes.acquired,
                auditEvent: .resourceLockAcquired,
                task: task,
                claim: claim,
                status: "acquired",
                modelContext: modelContext,
                autoExport: false
            )
        }
        return claims
    }

    @MainActor
    @discardableResult
    func acquireResourceLockIfAvailable(
        task: AgentTask,
        resourceKey: String? = nil,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        modelContext: ModelContext? = nil
    ) -> TaskResourceLockClaim? {
        let claim = TaskResourceLockClaim(
            taskID: task.id,
            resourceKey: resourceKey ?? self.resourceKey(for: task),
            accessMode: accessMode,
            runMode: runMode
        )
        return acquireResourceLocksIfAvailable([claim], task: task, modelContext: modelContext)?.first
    }

    @MainActor
    func releaseResourceLocks(
        _ claims: [TaskResourceLockClaim],
        task: AgentTask,
        modelContext: ModelContext? = nil
    ) {
        let released = Set(claims)
        activeResourceLocks.removeAll { released.contains($0) }
        waitingResourceLocks.removeValue(forKey: task.id)
        for (index, claim) in claims.enumerated() {
            recordResourceLockEvent(
                type: TaskResourceLockEventTypes.released,
                auditEvent: .resourceLockReleased,
                task: task,
                claim: claim,
                status: "released",
                modelContext: modelContext,
                autoExport: index == claims.count - 1
            )
        }
        wakeAllTurnAdmissionWaiters()
    }

    @MainActor
    func releaseResourceLock(
        _ claim: TaskResourceLockClaim,
        task: AgentTask,
        modelContext: ModelContext? = nil
    ) {
        releaseResourceLocks([claim], task: task, modelContext: modelContext)
    }

    @MainActor
    private func waitForResourceLocks(
        task: AgentTask,
        claims: [TaskResourceLockClaim],
        modelContext: ModelContext,
        shouldAbort: (() -> Bool)? = nil
    ) async -> [TaskResourceLockClaim]? {
        guard !claims.isEmpty, !(shouldAbort?() ?? false) else { return nil }
        for claim in claims {
            recordResourceLockEvent(
                type: TaskResourceLockEventTypes.requested,
                auditEvent: .resourceLockRequested,
                task: task,
                claim: claim,
                status: "requested",
                modelContext: modelContext,
                autoExport: false
            )
        }

        var recordedWaiting = false
        while !Task.isCancelled && !(shouldAbort?() ?? false) {
            if let acquired = acquireResourceLocksIfAvailable(
                claims,
                task: task,
                modelContext: modelContext
            ) {
                return acquired
            }

            let conflict = TaskExecutionResourceBroker.firstConflict(
                requested: claims,
                active: activeResourceLocks
            )
            let primary = conflict?.requested ?? claims[0]
            waitingResourceLocks[task.id] = primary
            if !recordedWaiting {
                recordResourceLockEvent(
                    type: TaskResourceLockEventTypes.waiting,
                    auditEvent: .resourceLockWaiting,
                    task: task,
                    claim: primary,
                    status: "waiting",
                    reason: TaskExecutionResourceBroker.blockerSummary(
                        requested: claims,
                        active: activeResourceLocks
                    ),
                    modelContext: modelContext,
                    autoExport: false
                )
                recordedWaiting = true
            }

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                waitingResourceLocks.removeValue(forKey: task.id)
                return nil
            }
        }

        waitingResourceLocks.removeValue(forKey: task.id)
        return nil
    }

    @MainActor
    private func recordForkReadOnlyBlock(
        _ task: AgentTask,
        reason: String,
        modelContext: ModelContext
    ) {
        guard !task.events.contains(where: {
            $0.type == TaskEventTypes.System.info.rawValue && $0.payload == reason
        }) else { return }
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: reason
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: [
                "operation": "git_conversation_fork_read_only_block",
                "result": "blocked"
            ]
        )
    }

    @MainActor
    private func recordResourceLockEvent(
        type: String,
        auditEvent: AuditEvent,
        task: AgentTask,
        claim: TaskResourceLockClaim,
        status: String,
        reason: String? = nil,
        modelContext: ModelContext?,
        autoExport: Bool = true
    ) {
        TaskResourceLockEventRecorder.record(
            type: type,
            auditEvent: auditEvent,
            task: task,
            claim: claim,
            status: status,
            reason: reason,
            modelContext: modelContext,
            activeClaims: activeResourceLocks,
            autoExport: autoExport
        )
    }

    // MARK: - Template Hooks Injection

    /// Injects template hooks into .claude/settings.local.json before task execution.
    /// Returns the original file data for restoration, or nil if no hooks to inject.
    private func injectTemplateHooks(for task: AgentTask) -> Data? {
        let backup = ClaudeSettingsStore.injectTemplateHooks(
            hooksJSON: task.templateHooksJSON,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        )
        if backup != nil || (!task.templateHooksJSON.isEmpty && task.templateHooksJSON != "{}") {
            AppLogger.audit(.taskStats, category: "Queue", taskID: task.id, fields: [
                "event": "template_hooks_injected"
            ])
        }
        return backup
    }

    /// Restores .claude/settings.local.json after task execution.
    private func restoreTemplateHooks(for task: AgentTask, backup: Data?) {
        ClaudeSettingsStore.restoreTemplateHooks(
            hooksJSON: task.templateHooksJSON,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            backup: backup
        )
        if backup != nil {
            AppLogger.audit(.taskStats, category: "Queue", taskID: task.id, fields: [
                "event": "template_hooks_restored"
            ])
        } else if !task.templateHooksJSON.isEmpty, task.templateHooksJSON != "{}" {
            AppLogger.audit(.taskStats, category: "Queue", taskID: task.id, fields: [
                "event": "template_hooks_removed"
            ])
        }
    }
}
