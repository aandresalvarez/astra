import Foundation
import SwiftData
import ASTRAModels

/// Read-only request-native queue projection. Durable execution requests are
/// the only queue entries; task status is an execution result/presentation
/// concern and must never decide whether accepted work still exists.
@MainActor
enum ExecutionRequestAdmissionScheduler {
    struct Candidate {
        let request: TaskTurnRequest
        let task: AgentTask
    }

    struct Projection {
        let activeRequests: [TaskTurnRequest]
        let ordered: [Candidate]
        let missingTaskRequests: [TaskTurnRequest]
    }

    static func projection(in modelContext: ModelContext) throws -> Projection {
        let requests = try TaskTurnRequestRepository.allActiveRequests(
            in: modelContext,
            sortBy: [SortDescriptor(\.submittedAt), SortDescriptor(\.sequence)]
        )
        guard !requests.isEmpty else {
            return Projection(activeRequests: [], ordered: [], missingTaskRequests: [])
        }

        let taskIDs = Array(Set(requests.map(\.taskID)))
        let tasks = try modelContext.fetch(
            FetchDescriptor<AgentTask>(predicate: #Predicate { taskIDs.contains($0.id) })
        )
        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // `requests` is globally oldest-first. Keeping only the first request
        // per task enforces strict task-local FIFO while allowing a blocked
        // task to be skipped in favor of unrelated projects.
        var seenTaskIDs: Set<UUID> = []
        var ordered: [Candidate] = []
        var missing: [TaskTurnRequest] = []
        for request in requests {
            guard let task = tasksByID[request.taskID] else {
                missing.append(request)
                continue
            }
            guard seenTaskIDs.insert(request.taskID).inserted else { continue }
            ordered.append(Candidate(request: request, task: task))
        }
        return Projection(activeRequests: requests, ordered: ordered, missingTaskRequests: missing)
    }

    static func synthesizeLegacyQueuedRequests(in modelContext: ModelContext) {
        let queued = TaskStatus.queued
        let tasks = (try? modelContext.fetch(
            FetchDescriptor<AgentTask>(predicate: #Predicate { $0.status == queued })
        )) ?? []
        for task in tasks where (try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext).isEmpty) == true {
            _ = ExecutionRequestSubmissionService.submitInitial(for: task, into: modelContext)
        }
    }

    /// Select the oldest request that is safe to admit now. Callers supply
    /// process-local ownership because workers and acquired locks deliberately
    /// are not persisted as a second scheduler authority.
    static func nextCandidate(
        from projection: Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>,
        resourceIsAvailable: (AgentTask) -> Bool
    ) -> Candidate? {
        projection.ordered.first {
            !dispatchedRequestIDs.contains($0.request.id)
                && !activeTaskIDs.contains($0.task.id)
                && resourceIsAvailable($0.task)
        }
    }
}
