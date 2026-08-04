import Foundation
import ASTRAModels
import ASTRAPersistence

extension TaskQueue {
    @MainActor
    func resourceAccess(for task: AgentTask) -> TaskResourceAccessMode {
        let access = TaskExecutionResourceAdmissionPolicy.effectiveWorkspaceAccess(
            TaskExecutionResourceClaimResolver.workspaceAccess(for: task),
            sandboxEnforcement: sandboxEnforcementProvider()
        )
        return access == .shared ? .readOnly : .write
    }

    @MainActor
    func resourceAccess(for request: TaskTurnRequest?, task: AgentTask) -> TaskResourceAccessMode {
        let persisted = TaskExecutionResourceClaimResolver.workspaceClaim(
            for: request,
            task: task
        )?.access ?? .exclusive
        let access = TaskExecutionResourceAdmissionPolicy.effectiveWorkspaceAccess(
            persisted,
            sandboxEnforcement: sandboxEnforcementProvider()
        )
        return access == .shared ? .readOnly : .write
    }

    @MainActor
    func resourceKey(for task: AgentTask) -> String {
        TaskExecutionResourceClaimResolver.workspaceClaim(for: nil, task: task)?.key
            ?? "task:\(task.id.uuidString)"
    }

    @MainActor
    func resourceKey(for request: TaskTurnRequest?, task: AgentTask) -> String {
        TaskExecutionResourceClaimResolver.workspaceClaim(for: request, task: task)?.key
            ?? resourceKey(for: task)
    }

    @MainActor
    func resourceLockClaims(
        for request: TaskTurnRequest?,
        task: AgentTask,
        runMode: String,
        fallbackAccess: TaskResourceAccessMode? = nil,
        sandboxEnforcement: ExecutionSandboxEnforcement? = nil
    ) -> [TaskResourceLockClaim] {
        TaskExecutionResourceAdmissionPolicy.lockClaims(
            for: request,
            task: task,
            runMode: runMode,
            fallbackAccess: fallbackAccess,
            sandboxEnforcement: sandboxEnforcement ?? sandboxEnforcementProvider()
        )
    }

    @MainActor
    func canAcquireResourceLocks(_ claims: [TaskResourceLockClaim]) -> Bool {
        !claims.isEmpty && TaskExecutionResourceBroker.canAcquire(
            claims,
            active: activeResourceLocks
        )
    }

    @MainActor
    func canAdmitResourceClaims(
        for candidate: ExecutionRequestAdmissionScheduler.Candidate,
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>
    ) -> Bool {
        TaskExecutionResourceAdmissionPolicy.canAdmit(
            candidate,
            in: projection,
            dispatchedRequestIDs: dispatchedRequestIDs,
            activeTaskIDs: activeTaskIDs,
            activeClaims: activeResourceLocks,
            sandboxEnforcement: sandboxEnforcementProvider()
        )
    }

    @MainActor
    func canAcquireResourceLock(
        for task: AgentTask,
        resourceKey: String? = nil,
        accessMode: TaskResourceAccessMode
    ) -> Bool {
        canAcquireResourceLocks([
            TaskResourceLockClaim(
                taskID: task.id,
                resourceKey: resourceKey ?? self.resourceKey(for: task),
                accessMode: accessMode,
                runMode: "probe"
            )
        ])
    }
}
