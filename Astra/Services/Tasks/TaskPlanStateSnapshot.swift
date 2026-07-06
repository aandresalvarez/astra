import Foundation
import ASTRAModels

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
}
