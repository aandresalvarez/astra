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
        fallbackAccess: TaskResourceAccessMode? = nil,
        sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
    ) -> [TaskResourceLockClaim] {
        var claims = TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task)
        if request == nil,
           !TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: request, task: task),
           let fallbackAccess,
           let index = claims.firstIndex(where: { $0.kind == .workspace }) {
            let workspace = claims[index]
            claims[index] = TaskExecutionResourceClaim(
                kind: workspace.kind,
                key: workspace.key,
                access: fallbackAccess == .readOnly ? .shared : .exclusive
            )
        }
        claims = effectiveClaims(claims, sandboxEnforcement: sandboxEnforcement)
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
        activeClaims: [TaskResourceLockClaim],
        sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
    ) -> Bool {
        let claims = lockClaims(
            for: candidate.request,
            task: candidate.task,
            runMode: "request",
            sandboxEnforcement: sandboxEnforcement
        )
        // A request with no resource claims (e.g. a no-workspace task routed to the
        // direct worker path) has nothing to conflict on and must be immediately
        // admissible; only requests that hold claims go through the broker's
        // conflict check.
        guard claims.isEmpty || TaskExecutionResourceBroker.canAcquire(claims, active: activeClaims) else {
            return false
        }
        return earlierCompetingClaim(
            for: candidate,
            claims: claims,
            in: projection,
            dispatchedRequestIDs: dispatchedRequestIDs,
            activeTaskIDs: activeTaskIDs,
            sandboxEnforcement: sandboxEnforcement
        ) == nil
    }

    static func earlierCompetingClaim(
        for candidate: ExecutionRequestAdmissionScheduler.Candidate,
        claims: [TaskResourceLockClaim],
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>,
        sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
    ) -> TaskResourceLockClaim? {
        for earlier in projection.ordered {
            if earlier.request.id == candidate.request.id { break }
            guard !dispatchedRequestIDs.contains(earlier.request.id),
                  !activeTaskIDs.contains(earlier.task.id) else { continue }
            let earlierClaims = lockClaims(
                for: earlier.request,
                task: earlier.task,
                runMode: "request",
                sandboxEnforcement: sandboxEnforcement
            )
            if let claim = claims.first(where: { requested in
                earlierClaims.contains { TaskExecutionResourceBroker.claimsCompete($0, requested) }
            }) {
                return claim
            }
        }
        return nil
    }

    static func effectiveWorkspaceAccess(
        _ access: TaskExecutionResourceAccess,
        sandboxEnforcement: ExecutionSandboxEnforcement
    ) -> TaskExecutionResourceAccess {
        sandboxEnforcement == .off && access == .shared ? .exclusive : access
    }

    static func workspaceAccess(
        from lease: [TaskResourceLockClaim]
    ) -> TaskExecutionResourceAccess? {
        let workspaceClaims = lease.filter { $0.resourceKind == .workspace }
        guard !workspaceClaims.isEmpty else { return nil }
        return workspaceClaims.allSatisfy { $0.accessMode == .readOnly }
            ? .shared
            : .exclusive
    }

    private static func effectiveClaims(
        _ claims: [TaskExecutionResourceClaim],
        sandboxEnforcement: ExecutionSandboxEnforcement
    ) -> [TaskExecutionResourceClaim] {
        guard sandboxEnforcement == .off else { return claims }
        return claims.map { claim in
            guard claim.access == .shared,
                  claim.kind == .workspace || claim.kind == .gitCommonDirectory else {
                return claim
            }
            // Shared admission is only safe while a read-only execution
            // boundary can uphold it. With sandboxing explicitly Off, preserve
            // safety by serializing the run as a writer instead of silently
            // turning Seatbelt back on.
            return TaskExecutionResourceClaim(
                kind: claim.kind,
                key: claim.key,
                access: .exclusive
            )
        }
    }
}
