import Foundation
import SwiftData
import ASTRAModels

struct TaskPlanStateReadInput {
    let events: [TaskEvent]
    let recoveryRuns: [TaskRun]
}

/// Reads only the durable rows that can affect the plan projection. Ordinary
/// conversation history never needs to fault into memory to render plan UI.
///
/// The rows are matched by the task's persistent identity, through a checked
/// unwrap of the relationship. The optional chain made each of the four reads
/// below walk the whole table; see `TaskHistoryRead`.
@MainActor
enum TaskPlanStateReader {
    /// Nonisolated because `TaskPlanService.reconstruct(for:)` is: it runs on
    /// the caller's context exactly as the relationship read it replaces did.
    nonisolated static func read(owner: PersistentIdentifier, modelContext: ModelContext) throws -> TaskPlanStateReadInput {
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
                $0.task != nil && $0.task!.persistentModelID == owner && (
                    $0.type == created
                        || $0.type == updated
                        || $0.type == approved
                        || $0.type == cancelled
                )
            }
        ))
        let executionEvents = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task != nil && $0.task!.persistentModelID == owner && (
                    $0.type == executionStarted
                        || $0.type == executionCompleted
                        || $0.type == executionFailed
                )
            }
        ))
        let stepEvents = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task != nil && $0.task!.persistentModelID == owner && (
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

        // The nil branch is load-bearing and cannot be written as
        // `hasProtocolEvents != false`: that translates to SQL `!= 0`, and
        // three-valued logic drops NULL rows — silently losing recovered plan
        // progress for every run written before schema V17 (verified by
        // `v16StoreMigratesToUnknownProtocolMarkerFlag`).
        //
        // The two values are typed constants, not `nil` and `true` literals.
        // With the literals and the task check together, CI's compiler gave up
        // on the predicate ("unable to type-check this expression in
        // reasonable time"); the store is asked the same question either way.
        let unknown: Bool? = nil
        let marked: Bool? = true
        let runDescriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> {
                $0.task != nil && $0.task!.persistentModelID == owner
                    && ($0.hasProtocolEvents == unknown || $0.hasProtocolEvents == marked)
            },
            sortBy: [
                SortDescriptor(\TaskRun.startedAt),
                SortDescriptor(\TaskRun.id)
            ]
        )
        let recoveryRuns = try modelContext.fetch(runDescriptor)

        return TaskPlanStateReadInput(events: events, recoveryRuns: recoveryRuns)
    }
}
