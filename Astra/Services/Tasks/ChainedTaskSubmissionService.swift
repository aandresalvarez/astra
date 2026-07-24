import Foundation
import SwiftData
import ASTRAModels

@MainActor
enum ChainedTaskSubmissionService {
    static func create(from task: AgentTask, run: TaskRun, modelContext: ModelContext) {
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
        TaskStateMachine.enqueueChainedFollowUp(nextTask, modelContext: modelContext)
        nextTask.chainedFromID = task.id
        nextTask.runtimeID = task.runtimeID
        nextTask.runtimeExplicitlySelected = task.runtimeExplicitlySelected
        nextTask.executionRootPath = task.executionRootPath
        nextTask.executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        if !run.output.isEmpty {
            nextTask.inputs = ["Previous task output (\(task.title)):\n\(String(run.output.prefix(5000)))"]
        }
        nextTask.skills = task.skills
        TaskCapabilitySnapshotter.capture(for: nextTask)
        modelContext.insert(nextTask)
        let chainEvent = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.chained,
            payload: "Chained to next task: \(nextTask.title)"
        )
        modelContext.insert(chainEvent)

        guard case .success = ExecutionRequestSubmissionService.submitChained(
            sourceTaskID: task.id,
            for: nextTask,
            into: modelContext
        ) else {
            modelContext.delete(chainEvent)
            modelContext.delete(nextTask)
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "operation": "chained_execution_submission"
            ], level: .error)
            return
        }
        AppLogger.audit(.taskChained, category: "Worker", taskID: task.id, fields: [
            "next_task_id": nextTask.id.uuidString
        ])
    }
}
