import Foundation
import SwiftData
import ASTRAModels

/// Exact delivery evidence for the decision dock, read from its current
/// context. Existence queries and newest-first pages avoid materializing the
/// entire history when a recent completion already answers the question.
/// There is no history cutoff: intermediate plan steps never prove delivery.
@MainActor
enum TaskDeliverableHistoryReader {
    private static let pageSize = 32
    private static let sourceTypes = [
        TaskEventTypes.ExecutionRequest.retry.rawValue,
        TaskEventTypes.ExecutionRequest.resume.rawValue,
        TaskEventTypes.ExecutionRequest.permissionResume.rawValue,
        TaskEventTypes.ExecutionRequest.planStep.rawValue
    ]

    static func followsUpDeliveredRequest(
        ownerID: PersistentIdentifier, runID: UUID, startedAt: Date,
        in context: ModelContext
    ) throws -> Bool {
        let pending = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        let pendingEvents = pending.contains { $0 is TaskEvent }
        let pendingRuns = pending.contains { $0 is TaskRun }
        guard try startsConversation(ownerID: ownerID, runID: runID,
            pendingEvents: pendingEvents, in: context) else { return false }

        let approved = TaskEventTypes.Task.approved.rawValue
        let planFinished = TaskEventTypes.Plan.executionCompleted.rawValue
        let prefix = TaskDeliverableExpectation.userApprovalPayloadPrefix
        var met = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.timestamp < startedAt
                && ($0.type == planFinished || ($0.type == approved && $0.payload.starts(with: prefix)))
        })
        if !pendingEvents { met.fetchLimit = 1 }
        if try context.fetch(met).contains(where: {
            !$0.isDeleted && $0.task?.persistentModelID == ownerID && $0.timestamp < startedAt
                && ($0.type == planFinished || ($0.type == approved && $0.payload.hasPrefix(prefix)))
        }) { return true }

        let completed = TaskRunStopReason.completed.rawValue
        var runs = FetchDescriptor<TaskRun>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.startedAt < startedAt && $0.stopReason == completed
        }, sortBy: [SortDescriptor(\TaskRun.startedAt, order: .reverse), SortDescriptor(\TaskRun.id, order: .reverse)])
        runs.fetchLimit = pageSize
        while true {
            let page = try context.fetch(runs)
            if try containsDelivery(page, ownerID: ownerID, startedAt: startedAt, in: context) { return true }
            if pendingRuns {
                // SwiftData merges pending rows around fetchLimit/offset.
                // Keep the positive first-page fast path, but never advance
                // an offset through a table with unsaved run changes.
                runs.fetchLimit = nil
                runs.fetchOffset = nil
                let remaining = try context.fetch(runs)
                for start in stride(from: 0, to: remaining.count, by: pageSize) {
                    let batch = Array(remaining[start..<min(start + pageSize, remaining.count)])
                    if try containsDelivery(batch, ownerID: ownerID, startedAt: startedAt, in: context) { return true }
                }
                return false
            }
            if page.count < pageSize { return false }
            runs.fetchOffset = (runs.fetchOffset ?? 0) + page.count
        }
    }

    private static func containsDelivery(
        _ runs: [TaskRun], ownerID: PersistentIdentifier, startedAt: Date, in context: ModelContext
    ) throws -> Bool {
        let candidates = Set(runs.filter {
            !$0.isDeleted && $0.task?.persistentModelID == ownerID && $0.startedAt < startedAt
                && $0.status == .completed && $0.stopReason == TaskRunStopReason.completed.rawValue
        }.map(\.id))
        guard !candidates.isEmpty else { return false }
        let planRuns = try approvedPlanRuns(ownerID: ownerID, runIDs: candidates, in: context)
        return !candidates.isSubset(of: planRuns)
    }

    private static func startsConversation(
        ownerID: PersistentIdentifier, runID: UUID, pendingEvents: Bool, in context: ModelContext
    ) throws -> Bool {
        let target: UUID? = runID
        let userMessage = TaskEventTypes.Conversation.userMessage.rawValue
        var message = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == target && $0.type == userMessage
        })
        if !pendingEvents { message.fetchLimit = 1 }
        if try context.fetch(message).contains(where: {
            !$0.isDeleted && $0.task?.persistentModelID == ownerID && $0.run?.id == target && $0.type == userMessage
        }) { return true }

        let types = sourceTypes
        let sources = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == target && types.contains($0.type)
        })
        return try context.fetch(sources).contains {
            !$0.isDeleted && $0.task?.persistentModelID == ownerID && $0.run?.id == target
                && types.contains($0.type)
                && TaskDeliverableExpectation.requestSource(type: $0.type, payload: $0.payload) == .conversation
        }
    }

    private static func approvedPlanRuns(
        ownerID: PersistentIdentifier, runIDs: Set<UUID>, in context: ModelContext
    ) throws -> Set<UUID> {
        let targets = Array(runIDs)
        let types = sourceTypes
        // One complete query for this run batch: source pages can lose rows
        // when SwiftData merges pending inserts/deletions around an offset.
        let sources = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID
                && $0.run.flatMap { targets.contains($0.id) } == true && types.contains($0.type)
        })
        var result: Set<UUID> = []
        for event in try context.fetch(sources) where !event.isDeleted
            && event.task?.persistentModelID == ownerID && types.contains(event.type)
            && TaskDeliverableExpectation.requestSource(type: event.type, payload: event.payload) == .approvedPlan {
            if let runID = event.run?.id, runIDs.contains(runID) { result.insert(runID) }
        }
        return result
    }
}
