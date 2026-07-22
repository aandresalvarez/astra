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

        // Sequence is the durable task-local FIFO authority. Timestamps order
        // the head request from each task globally, but must never let a later
        // sequence overtake an earlier turn after import/clock adjustment.
        var headsByTaskID: [UUID: Candidate] = [:]
        var missing: [TaskTurnRequest] = []
        for request in requests {
            guard let task = tasksByID[request.taskID] else {
                missing.append(request)
                continue
            }
            let candidate = Candidate(request: request, task: task)
            if let current = headsByTaskID[request.taskID] {
                if request.sequence < current.request.sequence
                    || (request.sequence == current.request.sequence
                        && request.submittedAt < current.request.submittedAt) {
                    headsByTaskID[request.taskID] = candidate
                }
            } else {
                headsByTaskID[request.taskID] = candidate
            }
        }
        let ordered = headsByTaskID.values.sorted {
            if $0.request.submittedAt != $1.request.submittedAt {
                return $0.request.submittedAt < $1.request.submittedAt
            }
            if $0.request.sequence != $1.request.sequence {
                return $0.request.sequence < $1.request.sequence
            }
            return $0.request.id.uuidString < $1.request.id.uuidString
        }
        return Projection(activeRequests: requests, ordered: ordered, missingTaskRequests: missing)
    }

    /// Select the oldest request that is safe to admit now. Callers supply
    /// process-local ownership because workers and acquired locks deliberately
    /// are not persisted as a second scheduler authority.
    static func nextCandidate(
        from projection: Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>,
        resourceIsAvailable: (Candidate) -> Bool
    ) -> Candidate? {
        projection.ordered.first {
            !dispatchedRequestIDs.contains($0.request.id)
                && !activeTaskIDs.contains($0.task.id)
                && resourceIsAvailable($0)
        }
    }
}
