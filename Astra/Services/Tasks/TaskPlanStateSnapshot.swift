import Foundation
import SwiftData
import ASTRAModels

/// Identifies when the plan projection can actually have changed.
///
/// `planEventRevision` counts durable plan-relevant event insertions observed
/// for the task rather than tracking `task.updatedAt`. Every runtime event
/// bumps `updatedAt`, so keying the refresh on it re-read the plan rows several
/// times per second and discarded ~97% of the results. Plan state can only move
/// when a plan-relevant event lands, when the task status changes, or when
/// protocol progress arrives in run output — the last of which is handled
/// separately because it only applies once a plan exists.
struct TaskPlanStateRefreshTrigger: Equatable {
    let taskID: UUID
    let status: TaskStatus
    let planEventRevision: Int

    init(task: AgentTask, planEventRevision: Int) {
        taskID = task.id
        status = task.status
        self.planEventRevision = planEventRevision
    }
}

/// Classifies durable event types that can move the plan projection. Mirrors
/// the event types `TaskPlanStateReader` fetches.
enum TaskPlanEventRelevance {
    static func affectsPlanState(eventType: String) -> Bool {
        TaskPlanService.stateMutationCode(for: eventType) != nil
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
