import Foundation
import SwiftData
import ASTRAModels

struct TaskPlanStateReadInput {
    let events: [TaskEvent]
    let recoveryRuns: [TaskRun]
}

/// Reads only the durable rows that can affect the plan projection. Ordinary
/// conversation history never needs to fault into memory to render plan UI.
@MainActor
enum TaskPlanStateReader {
    private static let recoveryRunLimit = 50

    static func read(taskID: UUID, modelContext: ModelContext) throws -> TaskPlanStateReadInput {
        let created = TaskPlanEventTypes.created
        let updated = TaskPlanEventTypes.updated
        let approved = TaskPlanEventTypes.approved
        let cancelled = TaskPlanEventTypes.cancelled
        let executionStarted = TaskPlanEventTypes.executionStarted
        let executionCompleted = TaskPlanEventTypes.executionCompleted
        let executionFailed = TaskPlanEventTypes.executionFailed
        let stepStarted = TaskPlanEventTypes.stepStarted
        let stepCompleted = TaskPlanEventTypes.stepCompleted
        let stepBlocked = TaskPlanEventTypes.stepBlocked
        let stepSkipped = TaskPlanEventTypes.stepSkipped
        let planEvents = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && (
                    $0.type == created
                        || $0.type == updated
                        || $0.type == approved
                        || $0.type == cancelled
                )
            }
        ))
        let executionEvents = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && (
                    $0.type == executionStarted
                        || $0.type == executionCompleted
                        || $0.type == executionFailed
                )
            }
        ))
        let stepEvents = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && (
                    $0.type == stepStarted
                        || $0.type == stepCompleted
                        || $0.type == stepBlocked
                        || $0.type == stepSkipped
                )
            }
        ))
        let events = (planEvents + executionEvents + stepEvents).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }

        var runDescriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.task?.id == taskID },
            sortBy: [
                SortDescriptor(\TaskRun.startedAt, order: .reverse),
                SortDescriptor(\TaskRun.id, order: .reverse)
            ]
        )
        runDescriptor.fetchLimit = recoveryRunLimit
        let recoveryRuns = try modelContext.fetch(runDescriptor)

        return TaskPlanStateReadInput(events: events, recoveryRuns: recoveryRuns)
    }
}
