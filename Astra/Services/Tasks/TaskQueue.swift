import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@Observable
final class TaskQueue {
    let poolSize: Int
    private let workerFactory: @MainActor () -> AgentRuntimeWorker
    private(set) var workers: [AgentRuntimeWorker]
    private(set) var isProcessing = false
    private(set) var isProcessingScheduled = false
    private var processingScheduleGeneration = 0

    /// Track which worker is running which task (by task ID)
    private(set) var taskWorkerMap: [UUID: AgentRuntimeWorker] = [:]

    /// Track active task IDs for status reporting
    var activeTasks: Set<UUID> = []

    /// Track exclusive/shared resource ownership so write-capable work cannot
    /// mutate the same checkout concurrently.
    private(set) var activeResourceLocks: [TaskResourceLockClaim] = []
    private(set) var waitingResourceLocks: [UUID: TaskResourceLockClaim] = [:]

    /// Track tasks that have been dispatched but may not yet be marked as .running.
    /// Prevents the queue loop from double-dispatching a task during the brief
    /// window between dispatch and the worker setting isRunning = true.
    private var dispatchedTasks: Set<UUID> = []

    @MainActor
    init(
        poolSize: Int = 3,
        workerFactory: @escaping @MainActor () -> AgentRuntimeWorker = { AgentRuntimeWorker() }
    ) {
        self.poolSize = poolSize
        self.workerFactory = workerFactory
        self.workers = (0..<poolSize).map { _ in workerFactory() }
    }

    /// Number of currently busy workers
    var activeCount: Int {
        workers.filter(\.isRunning).count
    }

    var hasActiveUpdateBlockingWork: Bool {
        AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: isProcessing,
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

    @discardableResult
    @MainActor
    func processQueueIfIdle(modelContext: ModelContext) -> Bool {
        guard !hasProcessingLoop else {
            return false
        }

        isProcessingScheduled = true
        processingScheduleGeneration += 1
        let generation = processingScheduleGeneration
        Task { @MainActor in
            guard self.isProcessingScheduled,
                  self.processingScheduleGeneration == generation else {
                return
            }
            self.isProcessingScheduled = false
            await self.processQueue(modelContext: modelContext)
        }
        return true
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
        resourceAccess: TaskResourceAccessMode = .write,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async {
        guard hasAvailableWorker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        guard let resourceClaim = await waitForResourceLock(
            task: task,
            accessMode: resourceAccess,
            runMode: "task",
            modelContext: modelContext
        ) else {
            return
        }
        defer {
            releaseResourceLock(resourceClaim, task: task, modelContext: modelContext)
        }

        guard let worker = nextAvailableWorker() else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy_after_resource_lock",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        guard admitQueuedTaskToRuntime(task, modelContext: modelContext, mode: "task") else {
            return
        }

        guard prepareTaskFolder(task, modelContext: modelContext, mode: "task") else {
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

        await worker.execute(task: task, modelContext: modelContext, onEvent: onEvent)

        // Restore hooks
        restoreTemplateHooks(for: task, backup: hooksBackup)

        taskWorkerMap.removeValue(forKey: task.id)
        activeTasks.remove(task.id)
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
                await executeTask(chainedTask, modelContext: modelContext, onEvent: onEvent)
            }
        }
    }

    /// Route a completed schedule-spawned task's results based on the schedule's resultMode.
    @MainActor
    private func routeScheduleResult(task: AgentTask, scheduleID: UUID, modelContext: ModelContext) {
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
                        modelContext.delete(task)
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
        modelContext: ModelContext,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        resourceAccess: TaskResourceAccessMode = .write,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async -> Bool {
        let lifecycle = ContinuationLaunchLifecycle(task: task)

        // Try to find the original worker, or use any available one
        guard taskWorkerMap[task.id] != nil || hasAvailableWorker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "no_worker_for_continue"
            ], level: .warning)
            recordContinuationAdmissionFailure(task, lifecycle: lifecycle, modelContext: modelContext)
            return false
        }

        guard let resourceClaim = await waitForResourceLock(
            task: task,
            accessMode: resourceAccess,
            runMode: "continue",
            modelContext: modelContext
        ) else {
            recordContinuationAdmissionFailure(task, lifecycle: lifecycle, modelContext: modelContext)
            return false
        }
        defer {
            releaseResourceLock(resourceClaim, task: task, modelContext: modelContext)
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
            modelContext: modelContext,
            executionPolicy: executionPolicy,
            onEvent: onEvent
        )
        taskWorkerMap.removeValue(forKey: task.id)
        return true
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
        resourceAccess: TaskResourceAccessMode = .write,
        onEvent: @escaping (ParsedEvent) -> Void = { _ in }
    ) async {
        guard hasAvailableWorker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy",
                "mode": "approved_plan",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        guard let resourceClaim = await waitForResourceLock(
            task: task,
            accessMode: resourceAccess,
            runMode: "approved_plan",
            modelContext: modelContext
        ) else {
            return
        }
        defer {
            releaseResourceLock(resourceClaim, task: task, modelContext: modelContext)
        }

        guard let worker = nextAvailableWorker() else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy_after_resource_lock",
                "mode": "approved_plan",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        guard admitQueuedTaskToRuntime(task, modelContext: modelContext, mode: "approved_plan") else {
            return
        }

        guard prepareTaskFolder(task, modelContext: modelContext, mode: "approved_plan") else {
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

        await worker.executeApprovedPlan(task: task, plan: plan, mode: mode, modelContext: modelContext, onEvent: onEvent)

        taskWorkerMap.removeValue(forKey: task.id)
        activeTasks.remove(task.id)
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

    /// Process all queued tasks, dispatching to available workers in parallel.
    @MainActor
    func processQueue(modelContext: ModelContext) async {
        guard !isProcessing else {
            AppLogger.audit(.workerBlocked, category: "Queue", fields: [
                "reason": "queue_already_processing"
            ], level: .warning)
            return
        }
        isProcessingScheduled = false
        isProcessing = true
        dispatchedTasks.removeAll()

        while !Task.isCancelled && isProcessing {
            guard hasAvailableWorker else {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { break } // CancellationError
                continue
            }

            let queuedStatus = TaskStatus.queued
            let descriptor = FetchDescriptor<AgentTask>(
                predicate: #Predicate { $0.status == queuedStatus },
                sortBy: [SortDescriptor(\.queuePosition)]
            )

            guard let tasks = try? modelContext.fetch(descriptor),
                  !tasks.isEmpty else {
                // Check if we still have dispatched tasks that haven't started yet
                if dispatchedTasks.isEmpty {
                    AppLogger.audit(.taskStats, category: "Queue", fields: [
                        "event": "queue_drained"
                    ])
                    break
                }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { break }
                continue
            }

            // Skip tasks already dispatched and tasks waiting on an exclusive
            // resource lock. Later tasks in different roots may still run.
            guard let next = tasks.first(where: {
                !dispatchedTasks.contains($0.id)
                    && canAcquireResourceLock(for: $0, accessMode: resourceAccess(for: $0))
            }) else {
                if let blocked = tasks.first(where: { !dispatchedTasks.contains($0.id) }) {
                    let accessMode = resourceAccess(for: blocked)
                    let claim = TaskResourceLockClaim(
                        taskID: blocked.id,
                        resourceKey: resourceKey(for: blocked),
                        accessMode: accessMode,
                        runMode: "task"
                    )
                    if waitingResourceLocks[blocked.id] == nil {
                        waitingResourceLocks[blocked.id] = claim
                        AppLogger.audit(.resourceLockWaiting, category: "Queue", taskID: blocked.id, fields: [
                            "resource_key": claim.resourceKey,
                            "access_mode": claim.accessMode.rawValue,
                            "run_mode": claim.runMode,
                            "reason": resourceLockBlockerSummary(for: claim)
                        ], level: .warning)
                    }
                }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { break }
                continue
            }

            // Mark as dispatched BEFORE firing the Task to prevent double-dispatch
            dispatchedTasks.insert(next.id)

            AppLogger.audit(.taskDequeued, category: "Queue", taskID: next.id, fields: [
                "queued_count": String(tasks.count),
                "active_count": String(activeCount),
                "pool_size": String(poolSize)
            ])

            let queue = self
            Task { @MainActor in
                await queue.executeTask(next, modelContext: modelContext, resourceAccess: queue.resourceAccess(for: next))
                queue.dispatchedTasks.remove(next.id)
            }

            // Brief yield to let the task start
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }

        // Wait for all remaining workers to finish
        while activeCount > 0 && !Task.isCancelled && isProcessing {
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { break }
        }

        dispatchedTasks.removeAll()
        isProcessing = false
    }

    /// Cancel a specific task's worker
    @MainActor
    func cancel(task: AgentTask) {
        if let worker = taskWorkerMap[task.id] {
            worker.cancel()
            taskWorkerMap.removeValue(forKey: task.id)
            AppLogger.audit(.taskCancelled, category: "Queue", taskID: task.id)
        }
    }

    /// Cancel all running workers
    @MainActor
    func cancelAll() {
        for worker in workers {
            worker.cancel()
        }
        taskWorkerMap.removeAll()
        activeTasks.removeAll()
        dispatchedTasks.removeAll()
        activeResourceLocks.removeAll()
        waitingResourceLocks.removeAll()
        isProcessingScheduled = false
        processingScheduleGeneration += 1
        isProcessing = false
        AppLogger.audit(.taskCancelled, category: "Queue", fields: [
            "scope": "all_workers"
        ])
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

    private func workerIndex(_ worker: AgentRuntimeWorker) -> Int {
        workers.firstIndex(where: { $0 === worker }) ?? 0
    }

    // MARK: - Resource Locks

    @MainActor
    func resourceAccess(for task: AgentTask) -> TaskResourceAccessMode {
        let declarations = task.constraints + task.inputs
        let normalized = declarations
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
            }
        let readOnlyMarkers = [
            "astra_resource_access=read_only",
            "astra_resource_access:read_only",
            "resource_access=read_only",
            "resource_access:read_only"
        ]
        if normalized.contains(where: { declaration in
            readOnlyMarkers.contains { marker in
                declaration.replacingOccurrences(of: " ", with: "").contains(marker)
            }
        }) {
            return .readOnly
        }
        return .write
    }

    @MainActor
    func resourceKey(for task: AgentTask) -> String {
        let access = TaskWorkspaceAccess(task: task)
        let rawPath = access.codeWorkingDirectory.isEmpty ? access.effectiveWorkspacePath : access.codeWorkingDirectory
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            return "task:\(task.id.uuidString)"
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    @MainActor
    func canAcquireResourceLock(for task: AgentTask, accessMode: TaskResourceAccessMode) -> Bool {
        canAcquireResourceLock(
            TaskResourceLockClaim(
                taskID: task.id,
                resourceKey: resourceKey(for: task),
                accessMode: accessMode,
                runMode: "probe"
            )
        )
    }

    @MainActor
    @discardableResult
    func acquireResourceLockIfAvailable(
        task: AgentTask,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        modelContext: ModelContext? = nil
    ) -> TaskResourceLockClaim? {
        let claim = TaskResourceLockClaim(
            taskID: task.id,
            resourceKey: resourceKey(for: task),
            accessMode: accessMode,
            runMode: runMode
        )
        guard canAcquireResourceLock(claim) else {
            return nil
        }
        activeResourceLocks.append(claim)
        waitingResourceLocks.removeValue(forKey: task.id)
        recordResourceLockEvent(
            type: TaskResourceLockEventTypes.acquired,
            auditEvent: .resourceLockAcquired,
            task: task,
            claim: claim,
            status: "acquired",
            modelContext: modelContext,
            autoExport: false
        )
        return claim
    }

    @MainActor
    func releaseResourceLock(
        _ claim: TaskResourceLockClaim,
        task: AgentTask,
        modelContext: ModelContext? = nil
    ) {
        activeResourceLocks.removeAll { $0 == claim }
        waitingResourceLocks.removeValue(forKey: task.id)
        recordResourceLockEvent(
            type: TaskResourceLockEventTypes.released,
            auditEvent: .resourceLockReleased,
            task: task,
            claim: claim,
            status: "released",
            modelContext: modelContext
        )
    }

    @MainActor
    private func waitForResourceLock(
        task: AgentTask,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        modelContext: ModelContext
    ) async -> TaskResourceLockClaim? {
        let claim = TaskResourceLockClaim(
            taskID: task.id,
            resourceKey: resourceKey(for: task),
            accessMode: accessMode,
            runMode: runMode
        )
        recordResourceLockEvent(
            type: TaskResourceLockEventTypes.requested,
            auditEvent: .resourceLockRequested,
            task: task,
            claim: claim,
            status: "requested",
            modelContext: modelContext,
            autoExport: false
        )

        var recordedWaiting = false
        while !Task.isCancelled {
            if let acquired = acquireResourceLockIfAvailable(
                task: task,
                accessMode: accessMode,
                runMode: runMode,
                modelContext: modelContext
            ) {
                return acquired
            }

            waitingResourceLocks[task.id] = claim
            if !recordedWaiting {
                recordResourceLockEvent(
                    type: TaskResourceLockEventTypes.waiting,
                    auditEvent: .resourceLockWaiting,
                    task: task,
                    claim: claim,
                    status: "waiting",
                    reason: resourceLockBlockerSummary(for: claim),
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

    private func canAcquireResourceLock(_ claim: TaskResourceLockClaim) -> Bool {
        let sameResourceLocks = activeResourceLocks.filter {
            resourceKeysConflict($0.resourceKey, claim.resourceKey)
        }
        guard !sameResourceLocks.isEmpty else { return true }
        switch claim.accessMode {
        case .readOnly:
            return sameResourceLocks.allSatisfy { $0.accessMode == .readOnly }
        case .write:
            return false
        }
    }

    private func resourceLockBlockerSummary(for claim: TaskResourceLockClaim) -> String {
        let blockers = activeResourceLocks
            .filter { resourceKeysConflict($0.resourceKey, claim.resourceKey) }
        guard !blockers.isEmpty else { return "resource lock unavailable" }
        let modes = blockers.map(\.accessMode.rawValue).joined(separator: ",")
        return "waiting for \(blockers.count) active \(modes) lock\(blockers.count == 1 ? "" : "s")"
    }

    private func resourceKeysConflict(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.hasPrefix("task:") || rhs.hasPrefix("task:") {
            return lhs == rhs
        }
        let left = URL(fileURLWithPath: lhs)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let right = URL(fileURLWithPath: rhs)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return left == right || isPath(left, ancestorOf: right) || isPath(right, ancestorOf: left)
    }

    private func isPath(_ possibleAncestor: String, ancestorOf path: String) -> Bool {
        let ancestor = possibleAncestor.hasSuffix("/") ? possibleAncestor : possibleAncestor + "/"
        return path.hasPrefix(ancestor)
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
        let holder = activeResourceLocks.first {
            $0.resourceKey == claim.resourceKey && $0.taskID != claim.taskID
        }?.taskID
        let payload = TaskResourceLockPayload(
            version: 1,
            resourceKey: claim.resourceKey,
            accessMode: claim.accessMode,
            runMode: claim.runMode,
            status: status,
            holderTaskID: holder,
            reason: reason
        )
        if let modelContext {
            modelContext.insert(TaskEvent(task: task, type: type, payload: encodeResourceLockPayload(payload)))
            // Requested/waiting/acquired all fire before executeTask admits
            // the task to .running, while the detached auto-export write for
            // this snapshot races the later, authoritative admission/terminal
            // export with no ordering guarantee — a losing race would leave
            // the workspace JSON mirror showing a stale queued task. Those
            // call sites pass autoExport: false; only released (which fires
            // at actual completion/cleanup) still exports.
            if autoExport {
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: ["operation": "resource_lock_event"]
                )
            } else {
                WorkspacePersistenceCoordinator.saveWithoutAutoExport(
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: ["operation": "resource_lock_event"]
                )
            }
        }
        AppLogger.audit(auditEvent, category: "Queue", taskID: task.id, fields: [
            "resource_key": claim.resourceKey,
            "access_mode": claim.accessMode.rawValue,
            "run_mode": claim.runMode,
            "status": status,
            "holder_task_id": holder?.uuidString ?? "none",
            "reason": reason ?? "none"
        ], level: type == TaskResourceLockEventTypes.waiting ? .warning : .info)
    }

    private func encodeResourceLockPayload(_ payload: TaskResourceLockPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
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
