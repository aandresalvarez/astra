import Foundation
import SwiftData
import ASTRAModels

struct TaskPlanStateRefreshTrigger: Equatable {
    let taskID: UUID
    let status: TaskStatus
    let revision: Date

    init(task: AgentTask) {
        taskID = task.id
        status = task.status
        revision = task.updatedAt
    }
}

struct TaskPlanStateSnapshot: Equatable {
    static let empty = TaskPlanStateSnapshot(
        state: .empty,
        signature: .empty
    )

    let state: TaskPlanState
    let signature: TaskPlanStateCacheSignature

    static func signature(for task: AgentTask) -> TaskPlanStateCacheSignature {
        TaskPlanStateCacheSignature(task: task)
    }

    static func build(for task: AgentTask) -> TaskPlanStateSnapshot {
        TaskPlanStateSnapshot(
            state: TaskPlanService.reconstruct(for: task),
            signature: signature(for: task)
        )
    }

    static func refreshed(for task: AgentTask, cached: TaskPlanStateSnapshot) -> TaskPlanStateSnapshot? {
        let signature = signature(for: task)
        guard cached.signature != signature else { return nil }
        return TaskPlanStateSnapshot(
            state: TaskPlanService.reconstruct(for: task),
            signature: signature
        )
    }

    @MainActor
    static func refreshed(
        for task: AgentTask,
        modelContext: ModelContext,
        cached: TaskPlanStateSnapshot
    ) throws -> TaskPlanStateSnapshot? {
        let input = try TaskPlanStateReader.read(taskID: task.id, modelContext: modelContext)
        let signature = TaskPlanStateCacheSignature(
            taskID: task.id,
            status: task.status,
            planEvents: input.events,
            recoveryRuns: input.recoveryRuns
        )
        guard cached.signature != signature else { return nil }
        return TaskPlanStateSnapshot(
            state: TaskPlanService.reconstruct(
                from: input.events,
                recoveryRuns: input.recoveryRuns
            ),
            signature: signature
        )
    }
}
