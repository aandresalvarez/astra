import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

/// A decision a person saved for one request before "Review workspace" began
/// ending the holders' reservations (`RuntimeWorkspaceReview`). None is
/// written any more. One already saved stays readable and valid for its
/// request until the holders it names release; a decision that was remembered
/// for a whole workspace (`workspaceScope`) no longer resolves anything.
struct RuntimeWorkspaceContinuationAuthorization: Codable, Equatable {
    struct Source: Codable, Equatable {
        let taskOwnerID: PersistentIdentifier
        let receipt: RuntimeExecutionOwnerRecord
        var reviewedSSHJobs: [ReviewedWorkspaceSSHJob]? = nil
        /// This holder's claims that the request named when the person
        /// decided. Absent on older decisions, which required all of them.
        var reviewedClaims: [TaskResourceLockClaim]? = nil
    }
    let taskID: UUID
    let taskOwnerID: PersistentIdentifier
    let requestID: UUID
    let sourceEventID: UUID
    let approvedAt: Date
    let sources: [Source]
    var beneficiaryReceiptDigest: String? = nil
    var workspaceScope: WorkspaceScope? = nil
    var inheritedAuthorizationID: UUID? = nil

    struct WorkspaceScope: Codable, Equatable {
        let workspaceID: UUID
        let workspaceOwnerID: PersistentIdentifier
        let claims: [TaskResourceLockClaim]
    }

    /// The same decision, for the holders that still reserve something.
    func covering(_ standing: [Source]) -> Self {
        .init(taskID: taskID, taskOwnerID: taskOwnerID, requestID: requestID, sourceEventID: sourceEventID,
              approvedAt: approvedAt, sources: standing, beneficiaryReceiptDigest: beneficiaryReceiptDigest,
              workspaceScope: workspaceScope, inheritedAuthorizationID: inheritedAuthorizationID)
    }
}

@MainActor
enum RuntimeWorkspaceContinuation {
    struct Admission {
        let authorization: RuntimeWorkspaceContinuationAuthorization
        let leases: [RuntimeExecutionOwnerStore.Lease]
        /// The reviewed holders' claims on what this request names. Anything
        /// else they hold stays reserved.
        var excludedClaims: Set<TaskResourceLockClaim> = []
    }

    /// The decision covers only what the request names. A holder's claim must
    /// either be named by the request (the same resource, or one inside a
    /// requested folder) or not conflict with it at all. A holder's private
    /// worktree is the usual second case: it stays reserved and unreviewed.
    /// A claim broader than the request cannot be continued over.
    nonisolated private static func named(_ held: [TaskResourceLockClaim],
                                          by requested: [TaskResourceLockClaim]) -> [TaskResourceLockClaim]? {
        var result: [TaskResourceLockClaim] = []
        for claim in held {
            if requested.contains(where: { TaskExecutionResourceBroker.names($0, resourceOf: claim) }) { result.append(claim) }
            else if !TaskExecutionResourceBroker.canAcquire(requested, active: [claim]) { return nil }
        }
        return result
    }

    /// Only a saved, manually submitted first turn can receive this exceptional
    /// grant. A schedule, chain, retry or imported same-UUID task cannot use it.
    static func isInitialInstruction(_ request: TaskTurnRequest, task: AgentTask, context: ModelContext) -> Bool {
        guard task.isLive, task.modelContext === context, request.modelContext === context,
              request.state.isActive, request.kind == .initial, request.startedAt == nil, request.runID == nil,
              (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID,
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task), source.run == nil,
              source.type == TaskEventTypes.ExecutionRequest.initial.rawValue,
              let payload = ExecutionRequestSubmissionService.decodeSourcePayload(source),
              payload.launchMode == .initial, payload.scheduleID == nil, payload.sourceTaskID == nil else { return false }
        return task.runs.isEmpty
    }

    static func admission(task: AgentTask, request: TaskTurnRequest?, previous logicalPrevious: RuntimeExecutionOwnerRecord?,
                          context: ModelContext, claims: [TaskResourceLockClaim]? = nil) throws -> Admission? {
        guard let request else { return nil }
        let store = RuntimeExecutionOwner.store(in: context)
        // Identity and lineage use the protected bytes, not the owner's in-memory
        // projection of a clean crash from stopped to finished.
        let previous = try RuntimeTaskOwnerJournal.read(task: task, context: context)
        guard previous?.executionID == logicalPrevious?.executionID,
              previous?.ownerID == logicalPrevious?.ownerID else { throw RuntimeExecutionOwnerStore.Failure.busy }
        // Only a decision saved for this request, or the one this task was
        // admitted on, is read. A decision remembered for the workspace is
        // not looked up: a new request there gets its own review.
        let existing = try store.workspaceContinuation(requestID: request.id)
        let authorizationID = existing?.requestID ?? previous?.workspaceContinuationRequestID ?? request.id
        guard var authorization = try existing ?? (authorizationID == request.id ? nil : store.workspaceContinuation(requestID: authorizationID)) else { return nil }
        // A saved decision covers holders. One whose reservation has since
        // ended needs no exception, and when none is left this is ordinary
        // admission. The request the decision admitted still resumes its own
        // interrupted preparation on it.
        let standing = try authorization.sources.filter { try holdsReservation($0, context: context) }
        let resumes = previous.map { $0.workspaceContinuationRequestID == authorizationID
            && resumesPreparation($0, task: task, request: request, context: context) } ?? false
        guard !standing.isEmpty || resumes else { return nil }
        authorization = authorization.covering(standing)
        if authorization.requestID != request.id, authorization.sources.contains(where: { $0.reviewedSSHJobs != nil }) { return nil }
        guard authorization.taskID == task.id, authorization.taskOwnerID == task.persistentModelID,
              authorization.requestID == authorizationID, request.state.isActive,
              let original = try TaskTurnRequestRepository.request(id: authorizationID, in: context),
              original.sourceEventID == authorization.sourceEventID,
              (try? TaskTurnRequestOwnership.resolve(original, in: context))?.persistentModelID == task.persistentModelID,
              isManualSource(original, task: task),
              (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        guard try RuntimeWorkspaceContinuationScope.validates(authorization, task: task, request: request,
            context: context, claims: claims, previous: previous) else { throw RuntimeExecutionOwnerStore.Failure.busy }
        if let previous {
            let freshDecision = try authorization.requestID == request.id
                && (authorization.inheritedAuthorizationID != nil || authorization.beneficiaryReceiptDigest == RuntimeExecutionOwnerStore.receiptDigest(previous))
                && isNewManualInstruction(request, task: task, previous: previous, context: context)
            guard freshDecision || (previous.workspaceContinuationRequestID == authorizationID
                && (resumesPreparation(previous, task: task, request: request, context: context)
                    || RuntimeCompletedUserTurnContinuation.permits(previous, task: task, request: request, context: context))) else { return nil }
        } else {
            guard isNewManualInstruction(request, task: task, previous: nil, context: context) else { return nil }
        }
        let requested = claims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_continuation", sandboxEnforcement: .off)
        // The launch must name exactly the holder claims the person reviewed:
        // a decision is neither stretched to another claim nor reused after
        // the request moved elsewhere. Older decisions reviewed every claim.
        var excluded: [TaskResourceLockClaim] = []
        for source in authorization.sources {
            let held = (source.receipt.resourceClaims ?? []).filter { $0.resourceKind != .nativeSession }
            guard let now = named(held, by: requested), Set(now) == Set(source.reviewedClaims ?? held),
                  source.reviewedClaims != nil || held.allSatisfy({ claim in
                      requested.contains { $0.resourceKind == claim.resourceKind && $0.resourceKey == claim.resourceKey && $0.accessMode == claim.accessMode }
                  }) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            excluded += now
        }
        let leases = authorization.sources.isEmpty ? [] : try lockSources(authorization, store: store, context: context)
        // A new task needs no exception once every reviewed owner has
        // independently released its resources. Use ordinary admission.
        if leases.isEmpty && previous == nil { return nil }
        return Admission(authorization: authorization, leases: leases,
            excludedClaims: Set(excluded.filter { $0.resourceKind == .workspace || $0.resourceKind == .gitCommonDirectory }))
    }

    /// Whether a reviewed holder still reserves anything. A holder that
    /// cannot be read is treated as holding, so `lockSources` fails closed.
    private static func holdsReservation(_ source: RuntimeWorkspaceContinuationAuthorization.Source,
                                         context: ModelContext) throws -> Bool {
        let id = source.receipt.taskID
        let candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
        guard let owner = candidates.first(where: { $0.persistentModelID == source.taskOwnerID }),
              let current = try RuntimeTaskOwnerJournal.read(task: owner, context: context) else { return true }
        return RuntimeResourceOwnership.retainsResources(current)
    }

    static func resumesPreparation(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask,
                                   request: TaskTurnRequest?, context: ModelContext) -> Bool {
        guard let request, saved.workspaceContinuationRequestID == request.id,
              saved.continuingUserRequestID == request.id, request.state.isActive,
              saved.taskOwnerID == task.persistentModelID, saved.taskID == task.id,
              saved.state == .preparing || saved.state == .notStarted,
              saved.providerProcess == nil, saved.stopProof == nil, saved.cancellationRequested != true,
              saved.settlementInProgress != true, saved.settlementLocalWorkStopped != false,
              saved.settlementToolsStopped != false,
              isManualSource(request, task: task),
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task),
              source.run == nil || source.run?.id == saved.runID,
              request.runID == nil || request.runID == saved.runID,
              request.startedAt == nil || (saved.runID != nil && request.runID == saved.runID) else { return false }
        return (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID
    }

    static func isNewManualInstruction(_ request: TaskTurnRequest, task: AgentTask,
                                       previous: RuntimeExecutionOwnerRecord?, context: ModelContext) -> Bool {
        guard task.isLive, task.modelContext === context, request.modelContext === context,
              request.state.isActive, request.taskID == task.id,
              (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID else { return false }
        guard let previous else {
            return isInitialInstruction(request, task: task, context: context)
                || followsLegacySettlement(request, task: task)
        }
        return (RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction
            && RuntimeCompletedUserTurnContinuation.hasCompletedTurn(previous, task: task, context: context))
            || followsUnlaunchedAttempt(request, task: task, previous: previous, context: context)
    }

    /// History from before the execution journal has no receipt. Ordinary
    /// admission already starts such a task on the older app's own settlement
    /// (`RuntimeRecoveryLegacyReconciliation`), so the person's new message
    /// there may receive the workspace decision on that same basis and no
    /// other. A task the journal ever tracked is not legacy: its missing
    /// receipt stays blocked. A retry replays an instruction that may have run.
    static func followsLegacySettlement(_ request: TaskTurnRequest, task: AgentTask) -> Bool {
        request.startedAt == nil && request.runID == nil
            && !RuntimeExecutionOwner.requiresExistingReceipt(task)
            && RuntimeRecoveryLegacyReconciliation.settledRun(of: task) != nil
            && RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction
    }

    /// Nothing of this task has run: its only saved execution ended with an
    /// explicit zero provider launches for its latest, failed run, and it holds
    /// no earlier execution of its own. The person's new message, or their own
    /// retry of that attempt, is then the instruction itself still waiting to
    /// start, not recovery of unverified work. A schedule, chain or plan step,
    /// a cancelled attempt, and an attempt that launched or spent anything
    /// stay excluded, exactly as before.
    static func followsUnlaunchedAttempt(_ request: TaskTurnRequest, task: AgentTask,
                                         previous: RuntimeExecutionOwnerRecord, context: ModelContext) -> Bool {
        guard previous.endedBeforeLaunch, previous.canReplace, previous.cancellationRequested != true,
              previous.taskID == task.id, previous.taskOwnerID == task.persistentModelID,
              request.startedAt == nil, request.runID == nil,
              let run = task.runs.max(by: { $0.startedAt < $1.startedAt }), run.status == .failed,
              previous.provesNoProviderLaunch(for: run),
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task), source.run == nil else { return false }
        return request.kind == .retry ? isManualSource(request, task: task)
            : RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction
    }

    static func isManualSource(_ request: TaskTurnRequest, task: AgentTask) -> Bool {
        if request.kind == .followUp {
            return TaskHistoryRead.event(id: request.sourceEventID, in: task)?.type == TaskEventTypes.Conversation.userMessage.rawValue
        }
        // Only the person's Retry submits this source. Whether a retry may use
        // a decision at all is decided by `followsUnlaunchedAttempt`.
        if request.kind == .retry {
            guard let source = TaskHistoryRead.event(id: request.sourceEventID, in: task),
                  source.type == TaskEventTypes.ExecutionRequest.retry.rawValue,
                  let payload = ExecutionRequestSubmissionService.decodeSourcePayload(source) else { return false }
            return payload.scheduleID == nil && payload.sourceTaskID == nil && payload.planSnapshot == nil
        }
        guard request.kind == .initial,
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task),
              source.type == TaskEventTypes.ExecutionRequest.initial.rawValue,
              let payload = ExecutionRequestSubmissionService.decodeSourcePayload(source) else { return false }
        return payload.launchMode == .initial && payload.scheduleID == nil && payload.sourceTaskID == nil
    }

    private static func lockSources(_ authorization: RuntimeWorkspaceContinuationAuthorization,
                                    store: RuntimeExecutionOwnerStore, context: ModelContext) throws -> [RuntimeExecutionOwnerStore.Lease] {
        guard !authorization.sources.isEmpty else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        var leases: [RuntimeExecutionOwnerStore.Lease] = []
        for source in authorization.sources {
            let saved = source.receipt
            let lease = try store.acquire(taskID: saved.taskID, taskOwnerID: saved.taskOwnerID)
            let id = saved.taskID
            let candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
            guard let owner = candidates.first(where: { $0.persistentModelID == source.taskOwnerID }),
                  let current = try RuntimeTaskOwnerJournal.read(task: owner, context: context),
                  current.ownerID == saved.ownerID, current.executionID == saved.executionID, current.runID == saved.runID,
                  RuntimeCompletedUserTurnContinuation.hasEndedTurn(current, task: owner, context: context) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            if source.reviewedSSHJobs != nil, current.resourcesReleased == true, current.canReplace { continue }
            guard current == saved else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let jobs = try RuntimeWorkspaceRemoteJobs.inventory(task: owner, owner: saved, context: context)
            try RuntimeWorkspaceRemoteJobs.check(jobs, reviewed: source.reviewedSSHJobs ?? [])
            leases.append(lease)
        }
        return leases
    }

    static func requireNoKnownRemoteWork(task: AgentTask, context: ModelContext) throws {
        // Use the complete task lineage and the same protected-cancellation
        // policy as workspace admission, including legacy cancelled-on-disk jobs.
        guard try RuntimeWorkspaceRemoteJobs.inventory(task: task, context: context).allSatisfy({ $0.status.isTerminal }) else {
            throw RuntimeExecutionOwnerStore.Failure.busy
        }
    }
}
