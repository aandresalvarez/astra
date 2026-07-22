import Foundation
import ASTRAModels

/// Projects durable claims into deterministic process-local leases and applies
/// per-resource FIFO fairness before the queue dispatches a worker.
@MainActor
enum TaskExecutionResourceAdmissionPolicy {
    static func lockClaims(
        for request: TaskTurnRequest?,
        task: AgentTask,
        runMode: String,
        fallbackAccess: TaskResourceAccessMode? = nil
    ) -> [TaskResourceLockClaim] {
        var claims = TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task)
        if request == nil,
           let fallbackAccess,
           let index = claims.firstIndex(where: { $0.kind == .workspace }) {
            let workspace = claims[index]
            claims[index] = TaskExecutionResourceClaim(
                kind: workspace.kind,
                key: workspace.key,
                access: fallbackAccess == .readOnly ? .shared : .exclusive
            )
        }
        return TaskExecutionResourceBroker.lockClaims(
            for: claims,
            taskID: task.id,
            requestID: request?.id,
            runMode: runMode
        )
    }

    static func canAdmit(
        _ candidate: ExecutionRequestAdmissionScheduler.Candidate,
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>,
        activeClaims: [TaskResourceLockClaim]
    ) -> Bool {
        let claims = lockClaims(for: candidate.request, task: candidate.task, runMode: "request")
        guard !claims.isEmpty,
              TaskExecutionResourceBroker.canAcquire(claims, active: activeClaims) else { return false }
        return earlierCompetingClaim(
            for: candidate,
            claims: claims,
            in: projection,
            dispatchedRequestIDs: dispatchedRequestIDs,
            activeTaskIDs: activeTaskIDs
        ) == nil
    }

    static func earlierCompetingClaim(
        for candidate: ExecutionRequestAdmissionScheduler.Candidate,
        claims: [TaskResourceLockClaim],
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>
    ) -> TaskResourceLockClaim? {
        for earlier in projection.ordered {
            if earlier.request.id == candidate.request.id { break }
            guard !dispatchedRequestIDs.contains(earlier.request.id),
                  !activeTaskIDs.contains(earlier.task.id) else { continue }
            let earlierClaims = lockClaims(
                for: earlier.request,
                task: earlier.task,
                runMode: "request"
            )
            if let claim = claims.first(where: { requested in
                earlierClaims.contains { TaskExecutionResourceBroker.claimsCompete($0, requested) }
            }) {
                return claim
            }
        }
        return nil
    }
}
