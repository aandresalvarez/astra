import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension TaskQueue {
    @MainActor
    func refreshResourceOwnership(in context: ModelContext) {
        let store = RuntimeExecutionOwner.store(in: context)
        resourceOwnershipStore = store
        waitingBanners = [:]
        do {
            try RuntimeReservationRelease.reconcile(in: store, context: context)
            persistedResourceLocks = try RuntimeResourceOwnership.claims(in: store, context: context)
            resourceOwnershipReadFailed = false
        } catch {
            // Preserve the last known holds. Unreadable authority never grants admission.
            resourceOwnershipReadFailed = true
        }
    }

    /// The loop that keeps a request waiting never refreshed ownership, so a
    /// holder whose process exited was noticed only when something else woke
    /// the queue. A counted pass, not a timer: every tenth pass of a loop
    /// that parks for half a second. Only the release rule is asked; the full
    /// ownership read follows when it ended a reservation.
    @MainActor
    func refreshOwnershipWhileWaiting(blocked: Bool, in context: ModelContext) {
        guard blocked else { waitingOwnershipPasses = 0; waitingBanners = [:]; return }
        waitingOwnershipPasses += 1
        guard waitingOwnershipPasses % Self.waitingOwnershipRefreshInterval == 0 else { return }
        // What a banner says is asked again on the pass that asks the rule.
        waitingBanners = [:]
        let ended = (try? RuntimeReservationRelease.reconcile(in: RuntimeExecutionOwner.store(in: context), context: context)) ?? 0
        if ended > 0 { refreshResourceOwnership(in: context) }
    }
    static let waitingOwnershipRefreshInterval = 10

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
        let inherited = continuingOwnerClaims(task: candidate.task, request: candidate.request)
        let excluded = workspaceContinuationClaims(task: candidate.task, request: candidate.request)
        let available = activeResourceLocks.filter { claim in
            !excluded.contains(claim) && (inherited.isEmpty || claim.taskID != candidate.task.id || claim.requestID == candidate.request.id)
        }
        return !resourceOwnershipReadFailed && TaskExecutionResourceAdmissionPolicy.canAdmit(
            candidate,
            in: projection,
            dispatchedRequestIDs: dispatchedRequestIDs,
            activeTaskIDs: activeTaskIDs,
            activeClaims: available,
            inheritedClaims: inherited,
            sandboxEnforcement: sandboxEnforcementProvider()
        )
    }

    @MainActor
    func continuingOwnerClaims(task: AgentTask, request: TaskTurnRequest?) -> [TaskResourceLockClaim] {
        guard !activeTasks.contains(task.id), let context = task.modelContext,
              let saved = try? RuntimeExecutionOwner.existing(task: task, context: context),
              RuntimeCompletedUserTurnContinuation.permits(saved, task: task, request: request, context: context)
                || RuntimeWorkspaceContinuation.resumesPreparation(saved, task: task, request: request, context: context) else { return [] }
        // An owner whose reservation ended keeps no place in line for it.
        return saved.resourcesReleased == true ? [] : saved.resourceClaims ?? []
    }

    @MainActor
    private func workspaceContinuationClaims(task: AgentTask, request: TaskTurnRequest?) -> Set<TaskResourceLockClaim> {
        guard !activeTasks.contains(task.id), let context = task.modelContext else { return [] }
        do {
            let saved = try RuntimeExecutionOwner.existing(task: task, context: context)
            return try RuntimeWorkspaceContinuation.admission(task: task, request: request, previous: saved,
                context: context)?.excludedClaims ?? []
        } catch { return [] }
    }

    @MainActor
    func canAcquireResourceLocks(_ claims: [TaskResourceLockClaim], task: AgentTask?, context: ModelContext?) -> Bool {
        guard let task, let context else { return canAcquireResourceLocks(claims) }
        let ids = Set(claims.compactMap(\.requestID))
        guard ids.count == 1, let id = ids.first,
              let request = try? TaskTurnRequestRepository.request(id: id, in: context) else {
            return canAcquireResourceLocks(claims)
        }
        let inherited = continuingOwnerClaims(task: task, request: request)
        let excluded = workspaceContinuationClaims(task: task, request: request)
        let available = activeResourceLocks.filter { claim in
            !excluded.contains(claim) && (inherited.isEmpty || claim.taskID != task.id || claim.requestID == id)
        }
        return !resourceOwnershipReadFailed && TaskExecutionResourceBroker.canAcquire(claims, active: available)
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

    /// The line on a waiting task: who holds the folder it waits for and the
    /// one thing in the way, as the release rule answers now
    /// (`RuntimeWorkspaceReviewWording.banner`). The loop that keeps a request
    /// waiting asks for it twice a second, and the answer can cost a lease, a
    /// lineage read and a look at the process table. So it is kept per holder
    /// until ownership is next refreshed or the rule is next asked, which is
    /// also when it can change. `request` and `task` say who waits: a request
    /// nobody can decide for is not told that it waits for the person.
    @MainActor
    func resourceBlockerSummary(_ claims: [TaskResourceLockClaim], modelContext: ModelContext,
                                request: TaskTurnRequest? = nil, task: AgentTask? = nil) -> String {
        let conflict = TaskExecutionResourceBroker.firstConflict(requested: claims, active: activeResourceLocks)
        let folders = RuntimeWorkspaceReviewWording.folders(conflict.map { [$0.requested] } ?? claims)
        if resourceOwnershipReadFailed { return RuntimeWorkspaceReviewWording.unreadableBanner(folders: folders) }
        func title(_ holderID: UUID) -> String? {
            try? modelContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == holderID })).first?.title
        }
        // Anything that is not a folder keeps the plain line.
        guard let conflict, !folders.isEmpty else {
            return TaskExecutionResourceBroker.blockerSummary(requested: claims, active: activeResourceLocks, holderTitle: title)
        }
        let overlap = TaskExecutionResourceBroker.containment(holder: conflict.holder, requested: conflict.requested)
        // A lock a working task holds in this process, or one that no single
        // saved record accounts for: it is at work, or cannot be told apart.
        let holders = persistedResourceLocks.contains(conflict.holder)
            ? ((try? resourceOwnershipStore?.records())?.filter { $0.resourceClaims?.contains(conflict.holder) == true } ?? []) : []
        guard holders.count == 1, let holder = holders.first, let store = resourceOwnershipStore,
              let owner = try? RuntimeReservationRelease.owner(of: holder, context: modelContext) else {
            return RuntimeWorkspaceReviewWording.banner(holder: title(conflict.holder.taskID), folders: folders,
                blockers: [.taskWorking], overlap: overlap)
        }
        // "Review workspace" decides about other tasks. A task that waits for
        // its own earlier run is told the fact, not told to act.
        let decidable = holder.taskID != task?.id
            && (request.flatMap { waiting in task.map { RuntimeWorkspaceReview.qualifies(waiting, task: $0, context: modelContext) } } ?? true)
        let key = WaitingBannerKey(executionID: holder.executionID, folders: folders, decidable: decidable, overlap: overlap)
        if let kept = waitingBanners[key], kept.holder == holder { return kept.text }
        // An answer that cannot be read is something ASTRA cannot confirm.
        let blockers = (try? RuntimeReservationRelease.standing(holder, task: owner, store: store, context: modelContext)) ?? [.lineageUnreadable]
        var jobs: [String: RuntimeWorkspaceReviewWording.SSHJob] = [:]
        if blockers.contains(where: { if case .sshJobs = $0 { true } else { false } }) {
            for (id, name) in RuntimeWorkspaceRemoteJobs.names(task: owner, owner: holder, context: modelContext) {
                jobs[id] = .init(label: name.label, host: name.host)
            }
        }
        let text = RuntimeWorkspaceReviewWording.banner(holder: owner.title, folders: folders, blockers: blockers,
            jobs: jobs, decidable: decidable, overlap: overlap)
        waitingBanners[key] = (holder, text)
        return text
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

/// One banner per holder, folder and kind of waiter.
struct WaitingBannerKey: Hashable {
    let executionID: UUID
    let folders: [String]
    let decidable: Bool
    let overlap: String?
}
