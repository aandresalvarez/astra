import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

@MainActor
enum ChainedTaskSubmissionService {
    static func create(from task: AgentTask, run: TaskRun, modelContext: ModelContext,
                       taskID: UUID? = nil, goal: String? = nil) {
        if let taskID {
            guard let existing = try? modelContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })) else { return }
            if let child = existing.first {
                guard child.chainedFromID == task.id else { return }
                if RuntimeSettlementProgress.event(TaskEventTypes.System.runtimeChainedWorkDispatched, task: task, run: run) == nil {
                    modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeChainedWorkDispatched,
                        payload: taskID.uuidString, run: run))
                    WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                }
                return
            }
        }
        let chainedGoal = goal ?? task.chainedGoal
        let nextTask = AgentTask(
            title: String(chainedGoal.prefix(60)),
            goal: chainedGoal,
            workspace: task.workspace,
            tokenBudget: task.tokenBudget,
            model: task.model,
            runtime: task.resolvedRuntimeID,
            isolationStrategy: task.isolationStrategy,
            validationStrategy: task.validationStrategy
        )
        if let taskID { nextTask.id = taskID }
        TaskStateMachine.enqueueChainedFollowUp(nextTask, modelContext: modelContext)
        nextTask.chainedFromID = task.id
        nextTask.runtimeID = task.runtimeID
        nextTask.runtimeExplicitlySelected = task.runtimeExplicitlySelected
        nextTask.reasoningEffort = task.reasoningEffort
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

        let receipt = taskID.map { id in
            TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeChainedWorkDispatched,
                payload: id.uuidString, run: run)
        }
        if let receipt { modelContext.insert(receipt) }
        guard case .success = ExecutionRequestSubmissionService.submitChained(
            sourceTaskID: task.id,
            for: nextTask,
            into: modelContext
        ) else {
            if let receipt { modelContext.delete(receipt) }
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
