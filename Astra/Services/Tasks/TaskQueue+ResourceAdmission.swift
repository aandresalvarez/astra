import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension TaskQueue {
    @MainActor
    func refreshResourceOwnership(in context: ModelContext) {
        let store = RuntimeExecutionOwner.store(in: context)
        resourceOwnershipStore = store
        do {
            persistedResourceLocks = try RuntimeResourceOwnership.claims(in: store, context: context)
            resourceOwnershipReadFailed = false
        } catch {
            // Preserve the last known holds. Unreadable authority never grants admission.
            resourceOwnershipReadFailed = true
        }
    }

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
        !resourceOwnershipReadFailed && !claims.isEmpty && TaskExecutionResourceBroker.canAcquire(
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
        !resourceOwnershipReadFailed && TaskExecutionResourceAdmissionPolicy.canAdmit(
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

    @MainActor
    @discardableResult
    func acquireResourceLockIfAvailable(
        task: AgentTask,
        resourceKey: String? = nil,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        modelContext: ModelContext? = nil
    ) -> TaskResourceLockClaim? {
        let claim = TaskResourceLockClaim(
            taskID: task.id,
            resourceKey: resourceKey ?? self.resourceKey(for: task),
            accessMode: accessMode,
            runMode: runMode
        )
        return acquireResourceLocksIfAvailable([claim], task: task, modelContext: modelContext)?.first
    }

    @MainActor
    func releaseResourceLock(
        _ claim: TaskResourceLockClaim,
        task: AgentTask,
        modelContext: ModelContext? = nil
    ) {
        releaseResourceLocks([claim], task: task, modelContext: modelContext)
    }

    /// The "Waiting for resource" text, naming the holding task from the store.
    @MainActor
    func resourceBlockerSummary(_ claims: [TaskResourceLockClaim], modelContext: ModelContext) -> String {
        if resourceOwnershipReadFailed {
            return "Waiting for recovery ownership to be readable. ASTRA cannot safely admit competing work."
        }
        let summary = TaskExecutionResourceBroker.blockerSummary(requested: claims, active: activeResourceLocks) { holderID in
            try? modelContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == holderID })).first?.title
        }
        guard let conflict = TaskExecutionResourceBroker.firstConflict(requested: claims, active: activeResourceLocks),
              persistedResourceLocks.contains(conflict.holder) else {
            return summary
        }
        let holder = try? resourceOwnershipStore?.read(taskID: conflict.holder.taskID)
        let awaitingCleanup = holder == nil || holder?.cancellationRequested == true
            || holder?.state == .unverified || holder?.appProcess.presence != .present
            || (holder?.state == .finished && holder?.canReplace != true)
        return summary + (awaitingCleanup ? " Previous execution cleanup is not yet confirmed." : "")
    }

    @MainActor
    func recordResourceLockEvent(
        type: String,
        auditEvent: AuditEvent,
        task: AgentTask,
        claim: TaskResourceLockClaim,
        status: String,
        reason: String? = nil,
        modelContext: ModelContext?,
        autoExport: Bool = true
    ) {
        TaskResourceLockEventRecorder.record(
            type: type,
            auditEvent: auditEvent,
            task: task,
            claim: claim,
            status: status,
            reason: reason,
            modelContext: modelContext,
            activeClaims: activeResourceLocks,
            autoExport: autoExport
        )
    }
}
