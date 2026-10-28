import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

extension TaskQueue {
    /// Route a completed schedule-spawned task's results based on the schedule's resultMode.
    @MainActor
    func routeScheduleResult(task: AgentTask, scheduleID: UUID, modelContext: ModelContext) {
        let workspaceOwnerID = task.workspace?.persistentModelID
        var descriptor = FetchDescriptor<TaskSchedule>(
            predicate: #Predicate<TaskSchedule> { $0.id == scheduleID && $0.workspace?.persistentModelID == workspaceOwnerID }
        )
        descriptor.fetchLimit = 2
        guard let schedules = try? modelContext.fetch(descriptor), schedules.count == 1,
              let schedule = schedules.first else { return }

        guard RuntimeTurnSettlementService.stageScheduleRouting(task: task, scheduleID: scheduleID,
            modelContext: modelContext) else { return }

        let lastRun = task.runs.sorted { $0.startedAt < $1.startedAt }.last
        let outputSummary = String((lastRun?.output ?? "No output").prefix(500))
        let statusStr = task.status.rawValue

        switch schedule.resultMode {
        case .sameThread:
            if let sourceTaskID = schedule.sourceTaskID {
                let workspaceOwner = schedule.workspace?.persistentModelID
                var sourceDescriptor = FetchDescriptor<AgentTask>(
                    predicate: #Predicate<AgentTask> { $0.id == sourceTaskID && $0.workspace?.persistentModelID == workspaceOwner }
                )
                sourceDescriptor.fetchLimit = 2
                if let matches = try? modelContext.fetch(sourceDescriptor), matches.count == 1,
                   let sourceTask = matches.first {
                    mergeSameThreadScheduleResult(
                        from: task,
                        into: sourceTask,
                        schedule: schedule,
                        latestRun: lastRun,
                        modelContext: modelContext
                    )

                    if task.persistentModelID != sourceTask.persistentModelID {
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

        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: schedule.workspace, modelContext: modelContext)
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
            copiedRun.setOutput(latestRun.output)
            copiedRun.costUSD = latestRun.costUSD
            copiedRun.fileChangesJSON = latestRun.fileChangesJSON
            copiedRun.stopReason = latestRun.stopReason
            modelContext.insert(copiedRun)

            sourceTask.tokensUsed = RuntimeUsageArithmetic.adding(sourceTask.tokensUsed, latestRun.tokensUsed)
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

}
