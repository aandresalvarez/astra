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
        guard try startsConversation(ownerID: ownerID, runID: runID, in: context) else { return false }

        let approved = TaskEventTypes.Task.approved.rawValue
        let planFinished = TaskEventTypes.Plan.executionCompleted.rawValue
        let prefix = TaskDeliverableExpectation.userApprovalPayloadPrefix
        var met = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.timestamp < startedAt
                && ($0.type == planFinished || ($0.type == approved && $0.payload.starts(with: prefix)))
        })
        met.fetchLimit = 1
        if try !context.fetch(met).isEmpty { return true }

        let completed = TaskRunStopReason.completed.rawValue
        var runs = FetchDescriptor<TaskRun>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.startedAt < startedAt && $0.stopReason == completed
        }, sortBy: [SortDescriptor(\TaskRun.startedAt, order: .reverse), SortDescriptor(\TaskRun.id, order: .reverse)])
        runs.fetchLimit = pageSize
        while true {
            let page = try context.fetch(runs)
            let candidates = Set(page.filter { !$0.isDeleted && $0.status == .completed }.map(\.id))
            if !candidates.isEmpty {
                let planRuns = try approvedPlanRuns(ownerID: ownerID, runIDs: candidates, in: context)
                if !candidates.isSubset(of: planRuns) { return true }
            }
            if page.count < pageSize { return false }
            runs.fetchOffset = (runs.fetchOffset ?? 0) + page.count
        }
    }

    private static func startsConversation(
        ownerID: PersistentIdentifier, runID: UUID, in context: ModelContext
    ) throws -> Bool {
        let target: UUID? = runID
        let userMessage = TaskEventTypes.Conversation.userMessage.rawValue
        var message = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == target && $0.type == userMessage
        })
        message.fetchLimit = 1
        if try !context.fetch(message).isEmpty { return true }

        let types = sourceTypes
        var sources = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == target && types.contains($0.type)
        }, sortBy: [SortDescriptor(\TaskEvent.timestamp), SortDescriptor(\TaskEvent.id)])
        sources.fetchLimit = pageSize
        while true {
            let page = try context.fetch(sources)
            if page.contains(where: {
                TaskDeliverableExpectation.requestSource(type: $0.type, payload: $0.payload) == .conversation
            }) { return true }
            if page.count < pageSize { return false }
            sources.fetchOffset = (sources.fetchOffset ?? 0) + page.count
        }
    }

    private static func approvedPlanRuns(
        ownerID: PersistentIdentifier, runIDs: Set<UUID>, in context: ModelContext
    ) throws -> Set<UUID> {
        let targets = Array(runIDs)
        let types = sourceTypes
        var sources = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID
                && $0.run.flatMap { targets.contains($0.id) } == true && types.contains($0.type)
        }, sortBy: [SortDescriptor(\TaskEvent.timestamp), SortDescriptor(\TaskEvent.id)])
        sources.fetchLimit = pageSize
        var result: Set<UUID> = []
        while true {
            let page = try context.fetch(sources)
            for event in page where TaskDeliverableExpectation.requestSource(type: event.type, payload: event.payload) == .approvedPlan {
                if let runID = event.run?.id { result.insert(runID) }
            }
            if page.count < pageSize || runIDs.isSubset(of: result) { return result }
            sources.fetchOffset = (sources.fetchOffset ?? 0) + page.count
        }
    }
}
