import Foundation
import SwiftData
import ASTRACore

@Observable
final class TaskQueue {
    let poolSize: Int
    private(set) var workers: [ClaudeCodeWorker]
    private(set) var isProcessing = false

    /// Track which worker is running which task (by task ID)
    private(set) var taskWorkerMap: [UUID: ClaudeCodeWorker] = [:]

    /// Track active task IDs for status reporting
    var activeTasks: Set<UUID> = []

    /// Track tasks that have been dispatched but may not yet be marked as .running.
    /// Prevents the queue loop from double-dispatching a task during the brief
    /// window between dispatch and the worker setting isRunning = true.
    private var dispatchedTasks: Set<UUID> = []

    @MainActor
    init(poolSize: Int = 3) {
        self.poolSize = poolSize
        self.workers = (0..<poolSize).map { _ in ClaudeCodeWorker() }
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

    /// Get the first available (idle) worker, or nil if all busy
    private func nextAvailableWorker() -> ClaudeCodeWorker? {
        workers.first { !$0.isRunning }
    }

    /// Get the worker assigned to a specific task
    func worker(for task: AgentTask) -> ClaudeCodeWorker? {
        taskWorkerMap[task.id]
    }

    /// Apply settings to all workers in the pool
    func applySettings(claudePath: String?, timeoutSeconds: TimeInterval, validationModel: String, skipPermissions: Bool = true) {
        for worker in workers {
            if let path = claudePath, !path.isEmpty {
                worker.claudePath = path
            }
            worker.timeoutSeconds = timeoutSeconds
            worker.validationModel = validationModel
            worker.skipPermissions = skipPermissions
        }
    }

    /// Execute a single task on the next available worker
    @MainActor
    func executeTask(_ task: AgentTask, modelContext: ModelContext, onEvent: @escaping (ParsedEvent) -> Void = { _ in }) async {
        guard let worker = nextAvailableWorker() else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "pool_busy",
                "pool_size": String(poolSize)
            ], level: .warning)
            return
        }

        do {
            try task.ensureTaskFolder()
        } catch {
            AppLogger.audit(.taskFailed, category: "Queue", taskID: task.id, fields: [
                "reason": "task_folder_create_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
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
                        type: "system.info",
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
            type: "user.message",
            payload: Self.sameThreadSchedulePrompt(schedule: schedule, fallbackGoal: scheduledTask.goal)
        )
        sourceMessage.timestamp = latestRun?.startedAt ?? Date()
        modelContext.insert(sourceMessage)

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

        sourceTask.status = scheduledTask.status
        sourceTask.isDone = false
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private static func sameThreadSchedulePrompt(schedule: TaskSchedule, fallbackGoal: String) -> String {
        let trimmedGoal = schedule.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmedGoal.isEmpty ? fallbackGoal : trimmedGoal
        return """
        Scheduled run: \(schedule.name)

        \(goal)
        """
    }

    /// Continue a session on the worker that originally ran the task
    @MainActor
    func continueSession(task: AgentTask, message: String, modelContext: ModelContext, onEvent: @escaping (ParsedEvent) -> Void = { _ in }) async {
        // Try to find the original worker, or use any available one
        let worker = taskWorkerMap[task.id] ?? nextAvailableWorker()
        guard let worker else {
            AppLogger.audit(.workerBlocked, category: "Queue", taskID: task.id, fields: [
                "reason": "no_worker_for_continue"
            ], level: .warning)
            return
        }

        taskWorkerMap[task.id] = worker
        await worker.continueSession(task: task, message: message, modelContext: modelContext, onEvent: onEvent)
        taskWorkerMap.removeValue(forKey: task.id)
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

            // Skip tasks already dispatched but not yet marked as .running
            guard let next = tasks.first(where: { !dispatchedTasks.contains($0.id) }) else {
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
                await queue.executeTask(next, modelContext: modelContext)
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
                workers.append(ClaudeCodeWorker())
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

    private func workerIndex(_ worker: ClaudeCodeWorker) -> Int {
        workers.firstIndex(where: { $0 === worker }) ?? 0
    }

    // MARK: - Template Hooks Injection

    /// Injects template hooks into .claude/settings.local.json before task execution.
    /// Returns the original file data for restoration, or nil if no hooks to inject.
    private func injectTemplateHooks(for task: AgentTask) -> Data? {
        let hooksJSON = task.templateHooksJSON
        guard !hooksJSON.isEmpty, hooksJSON != "{}" else { return nil }

        let workspacePath = task.effectiveWorkspacePath
        guard !workspacePath.isEmpty else { return nil }

        let settingsDir = (workspacePath as NSString).appendingPathComponent(".claude")
        let settingsPath = (settingsDir as NSString).appendingPathComponent("settings.local.json")
        let fm = FileManager.default

        // Read existing settings
        var settings: [String: Any] = [:]
        let backup: Data?
        if let existingData = fm.contents(atPath: settingsPath) {
            backup = existingData
            settings = (try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]) ?? [:]
        } else {
            backup = nil
        }

        // Parse template hooks
        guard let hooksData = hooksJSON.data(using: .utf8),
              let hooks = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any] else {
            return nil
        }

        // Merge hooks into settings
        var existingHooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]
        for (hookType, entries) in hooks {
            guard let entries = entries as? [[String: Any]] else { continue }
            var current = existingHooks[hookType] ?? []
            for entry in entries {
                // Tag injected hooks so we can clean them up
                var taggedEntry = entry
                taggedEntry["_astra_template"] = true
                current.append(taggedEntry)
            }
            existingHooks[hookType] = current
        }
        settings["hooks"] = existingHooks

        // Write back
        try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
            AppLogger.audit(.taskStats, category: "Queue", taskID: task.id, fields: [
                "event": "template_hooks_injected"
            ])
        }

        return backup
    }

    /// Restores .claude/settings.local.json after task execution.
    private func restoreTemplateHooks(for task: AgentTask, backup: Data?) {
        guard backup != nil || !task.templateHooksJSON.isEmpty else { return }
        guard task.templateHooksJSON != "{}", !task.templateHooksJSON.isEmpty else { return }

        let workspacePath = task.effectiveWorkspacePath
        guard !workspacePath.isEmpty else { return }

        let settingsPath = (workspacePath as NSString)
            .appendingPathComponent(".claude/settings.local.json")

        if let backup {
            // Restore original
            try? backup.write(to: URL(fileURLWithPath: settingsPath))
            AppLogger.audit(.taskStats, category: "Queue", taskID: task.id, fields: [
                "event": "template_hooks_restored"
            ])
        } else {
            // No original file existed — remove the injected one
            try? FileManager.default.removeItem(atPath: settingsPath)
            AppLogger.audit(.taskStats, category: "Queue", taskID: task.id, fields: [
                "event": "template_hooks_removed"
            ])
        }
    }
}
