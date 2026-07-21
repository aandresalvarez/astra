import Foundation
import ASTRAModels

/// Content-free operational projection for diagnosing concurrent execution.
/// It is derived from the scheduler's durable request projection so logging
/// cannot become a second queue owner or disagree about accepted work.
@MainActor
enum ExecutionRequestQueueSnapshot {
    static func fields(
        projection: ExecutionRequestAdmissionScheduler.Projection,
        now: Date = Date()
    ) -> [String: String] {
        let requests = projection.activeRequests
        let tasks = projection.ordered.map(\.task)
        let workspaceIDs = Set(tasks.compactMap { $0.workspace?.id })
        let oldestWaitSeconds = requests
            .map { max(0, now.timeIntervalSince($0.submittedAt)) }
            .max() ?? 0

        return [
            "active_request_count": String(requests.count),
            "admittable_task_count": String(projection.ordered.count),
            "active_task_count": String(Set(requests.map(\.taskID)).count),
            "active_workspace_count": String(workspaceIDs.count),
            "waiting_worker_count": String(requests.count { $0.state == .waitingForWorker }),
            "waiting_resource_count": String(requests.count { $0.state == .waitingForResource }),
            "admitted_count": String(requests.count { $0.state == .admitted }),
            "running_request_count": String(requests.count { $0.state == .running }),
            "orphan_request_count": String(projection.missingTaskRequests.count),
            "oldest_wait_seconds": String(Int(oldestWaitSeconds.rounded(.down)))
        ]
    }

    static func logDrained(
        projection: ExecutionRequestAdmissionScheduler.Projection,
        poolSize: Int,
        activeWorkerCount: Int
    ) {
        AppLogger.audit(.taskStats, category: "Queue", fields: fields(projection: projection).merging([
            "event": "queue_drained",
            "pool_size": String(poolSize),
            "active_worker_count": String(activeWorkerCount)
        ], uniquingKeysWith: { _, current in current }))
    }
}
