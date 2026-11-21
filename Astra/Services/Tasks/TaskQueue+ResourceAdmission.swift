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
        // Taken before the read, so a journal written during it is read next time.
        ownershipJournalStamp = Self.journalStamp(store)
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
        let store = RuntimeExecutionOwner.store(in: context)
        let ended = (try? RuntimeReservationRelease.reconcile(in: store, context: context)) ?? 0
        // A release this process did not make, by the rule or by a person's
        // decision in another ASTRA instance on the same store, leaves the
        // rule nothing to end here and the locks read earlier in place. It
        // does change the journal folder. So on every sixth asking pass,
        // about thirty seconds, the folder's change time is compared with the
        // one seen at the last full read, and ownership is read again when it
        // moved. The full read is too slow for every pass.
        let foreign = waitingOwnershipPasses % (Self.waitingOwnershipRefreshInterval * Self.foreignReleaseCheckInterval) == 0
            && Self.journalStamp(store) != ownershipJournalStamp
        if ended > 0 || foreign { refreshResourceOwnership(in: context) }
    }
    static let waitingOwnershipRefreshInterval = 10
    static let foreignReleaseCheckInterval = 6
    /// When the journal folder last gained, lost or replaced a file.
    static func journalStamp(_ store: RuntimeExecutionOwnerStore) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: store.root.path))?[.modificationDate] as? Date
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
        let conflicts = TaskExecutionResourceBroker.conflicts(requested: claims, active: activeResourceLocks)
        let folders = RuntimeWorkspaceReviewWording.folders(conflicts.first.map { [$0.requested] } ?? claims)
        if resourceOwnershipReadFailed { return RuntimeWorkspaceReviewWording.unreadableBanner(folders: folders) }
        func title(_ holderID: UUID) -> String? {
            try? modelContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == holderID })).first?.title
        }
        // Anything that is not a folder keeps the plain line.
        guard !conflicts.isEmpty, !folders.isEmpty else {
            return TaskExecutionResourceBroker.blockerSummary(requested: claims, active: activeResourceLocks, holderTitle: title)
        }
        // Every task that holds a folder this request names, once each, the
        // first conflict first. One that is still at work is the one to name:
        // nothing can be decided, here or in "Review workspace", until it ends.
        var first: String?
        var asked: Set<UUID> = []
        for conflict in conflicts where !RuntimeWorkspaceReviewWording.folders([conflict.requested]).isEmpty
            && asked.insert(conflict.holder.taskID).inserted {
            let answer = waitingBanner(for: conflict, modelContext: modelContext, request: request, task: task, title: title)
            if answer.active { return answer.text }
            first = first ?? answer.text
        }
        return first ?? TaskExecutionResourceBroker.blockerSummary(requested: claims, active: activeResourceLocks, holderTitle: title)
    }

    /// The line for one holder, and whether that holder is itself at work.
    @MainActor
    private func waitingBanner(for conflict: TaskExecutionResourceBroker.Conflict, modelContext: ModelContext,
                               request: TaskTurnRequest?, task: AgentTask?,
                               title: (UUID) -> String?) -> (text: String, active: Bool) {
        let folders = RuntimeWorkspaceReviewWording.folders([conflict.requested])
        let overlap = TaskExecutionResourceBroker.containment(holder: conflict.holder, requested: conflict.requested)
        // "Review workspace" decides about other tasks. A task that waits for
        // its own earlier run is told the fact, not told to act.
        let decidable = conflict.holder.taskID != task?.id
            && (request.flatMap { waiting in task.map { RuntimeWorkspaceReview.qualifies(waiting, task: $0, context: modelContext) } } ?? true)
        // Kept by the lock itself, so a kept answer reads no journal.
        let key = WaitingBannerKey(holder: conflict.holder, folders: folders, decidable: decidable, overlap: overlap)
        if let kept = waitingBanners[key] { return kept }
        func keep(_ text: String, active: Bool) -> (text: String, active: Bool) {
            waitingBanners[key] = (text, active)
            return (text, active)
        }
        // A lock a working task holds in this process has no saved record to ask.
        let records = persistedResourceLocks.contains(conflict.holder)
            ? ((try? resourceOwnershipStore?.records())?.filter { $0.resourceClaims?.contains(conflict.holder) == true } ?? []) : []
        guard !records.isEmpty, let store = resourceOwnershipStore else {
            return keep(RuntimeWorkspaceReviewWording.banner(holder: title(conflict.holder.taskID), folders: folders,
                blockers: [.taskWorking], overlap: overlap), active: true)
        }
        // Copies of one task can hold the same lock. Each is asked: one that is
        // at work is the one to name, and otherwise the first.
        var chosen: (record: RuntimeExecutionOwnerRecord, owner: AgentTask, blockers: [RuntimeReservationRelease.Blocker])?
        for record in records {
            guard let owner = try? RuntimeReservationRelease.owner(of: record, context: modelContext) else { continue }
            // An answer that cannot be read is something ASTRA cannot confirm.
            let blockers = (try? RuntimeReservationRelease.standing(record, task: owner, store: store, context: modelContext)) ?? [.lineageUnreadable]
            if blockers.contains(where: \.holderIsActive) { chosen = (record, owner, blockers); break }
            chosen = chosen ?? (record, owner, blockers)
        }
        // A record whose task cannot be told is not a task at work, and not one to decide about.
        guard let chosen else { return keep(RuntimeWorkspaceReviewWording.unreadableBanner(folders: folders), active: false) }
        var jobs: [String: RuntimeWorkspaceReviewWording.SSHJob] = [:]
        if chosen.blockers.contains(where: { if case .sshJobs = $0 { true } else { false } }) {
            for (id, name) in RuntimeWorkspaceRemoteJobs.names(task: chosen.owner, owner: chosen.record, context: modelContext) {
                jobs[id] = .init(label: name.label, host: name.host)
            }
        }
        return keep(RuntimeWorkspaceReviewWording.banner(holder: chosen.owner.title, folders: folders, blockers: chosen.blockers,
            jobs: jobs, decidable: decidable, overlap: overlap), active: chosen.blockers.contains(where: \.holderIsActive))
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
    let holder: TaskResourceLockClaim
    let folders: [String]
    let decidable: Bool
    let overlap: String?
}
