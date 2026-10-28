import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

/// A user decision, not proof that earlier tool effects stopped. The original
/// journals remain authoritative. Remembered workspace decisions authorize only
/// eligible manual successors; active and unrelated work remains fenced.
struct RuntimeWorkspaceContinuationAuthorization: Codable, Equatable {
    struct Source: Codable, Equatable {
        let taskOwnerID: PersistentIdentifier
        let receipt: RuntimeExecutionOwnerRecord
    }
    let taskID: UUID
    let taskOwnerID: PersistentIdentifier
    let requestID: UUID
    let sourceEventID: UUID
    let approvedAt: Date
    let sources: [Source]
    var workspaceScope: WorkspaceScope? = nil
    var inheritedAuthorizationID: UUID? = nil

    struct WorkspaceScope: Codable, Equatable {
        let workspaceID: UUID
        let workspaceOwnerID: PersistentIdentifier
        let claims: [TaskResourceLockClaim]
    }
}

@MainActor
enum RuntimeWorkspaceContinuation {
    struct Admission {
        let authorization: RuntimeWorkspaceContinuationAuthorization
        let leases: [RuntimeExecutionOwnerStore.Lease]
        var needsPersistence = false
        var excludedClaims: Set<TaskResourceLockClaim> {
            Set(authorization.sources.flatMap { $0.receipt.resourceClaims ?? [] })
        }
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

    /// Preview is advisory. authorize and runtime acquisition re-read under
    /// kernel leases; changing a holder while the dialog is open invalidates it.
    static func preview(task: AgentTask, request: TaskTurnRequest, context: ModelContext,
                        previous: RuntimeExecutionOwnerRecord? = nil) throws -> RuntimeWorkspaceContinuationAuthorization {
        guard isNewManualInstruction(request, task: task, previous: previous, context: context) else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let store = RuntimeExecutionOwner.store(in: context)
        let saved = try RuntimeTaskOwnerJournal.read(task: task, context: context)
        guard saved == previous,
              previous != nil || !RuntimeExecutionOwner.requiresExistingReceipt(task) else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let requested = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_continuation", sandboxEnforcement: .off)
        let held = try RuntimeResourceOwnership.claims(in: store, context: context, excluding: task.id, excludingOwner: task.persistentModelID)
        let conflicts = held.filter { !TaskExecutionResourceBroker.canAcquire(requested, active: [$0]) }
        guard !requested.isEmpty, !conflicts.isEmpty else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let records = try store.records()
        var sources: [RuntimeWorkspaceContinuationAuthorization.Source] = []
        for record in records where record.resourceClaims?.contains(where: conflicts.contains) == true {
            guard record.taskID != task.id, let claims = record.resourceClaims, !claims.isEmpty,
                  claims.allSatisfy({ $0.resourceKind == .workspace || $0.resourceKind == .gitCommonDirectory }),
                  // This action cannot silently authorize unrelated directories.
                  claims.allSatisfy({ claim in requested.contains { $0.resourceKind == claim.resourceKind && $0.resourceKey == claim.resourceKey && $0.accessMode == claim.accessMode } }) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let id = record.taskID
            let candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
            let owners = try candidates.filter { try RuntimeTaskOwnerJournal.read(task: $0, context: context) == record }
            guard owners.count == 1, let owner = owners.first,
                  RuntimeCompletedUserTurnContinuation.hasCompletedTurn(record, task: owner, context: context) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try requireNoKnownRemoteWork(task: owner, context: context)
            sources.append(.init(taskOwnerID: owner.persistentModelID, receipt: record))
        }
        let covered = Set(sources.flatMap { $0.receipt.resourceClaims ?? [] })
        guard Set(conflicts).isSubset(of: covered) else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        return .init(taskID: task.id, taskOwnerID: task.persistentModelID, requestID: request.id, sourceEventID: request.sourceEventID,
            approvedAt: Date(), sources: sources.sorted { $0.receipt.taskID.uuidString < $1.receipt.taskID.uuidString })
    }

    static func authorize(_ proposed: RuntimeWorkspaceContinuationAuthorization, task: AgentTask,
                          request: TaskTurnRequest, context: ModelContext, rememberWorkspace: Bool = false) throws {
        let store = RuntimeExecutionOwner.store(in: context)
        let admission = try store.acquireAdmission()
        let beneficiary = try RuntimeTaskOwnerJournal.acquire(task: task, context: context)
        defer { withExtendedLifetime((admission, beneficiary)) {} }
        guard proposed.workspaceScope == nil, proposed.inheritedAuthorizationID == nil else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let fresh = try preview(task: task, request: request, context: context)
        guard fresh.taskID == proposed.taskID, fresh.taskOwnerID == proposed.taskOwnerID,
              fresh.requestID == proposed.requestID, fresh.sourceEventID == proposed.sourceEventID, fresh.sources == proposed.sources else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let locked = try lockSources(proposed, store: store, context: context)
        defer { withExtendedLifetime(locked) {} }
        var authorization = proposed
        if rememberWorkspace {
            guard let workspace = task.workspace else { throw RuntimeExecutionOwnerStore.Failure.busy }
            authorization.workspaceScope = .init(workspaceID: workspace.id, workspaceOwnerID: workspace.persistentModelID,
                claims: TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
                    runMode: "workspace_continuation", sandboxEnforcement: .off))
        }
        try persist(authorization, task: task, lease: beneficiary, context: context)
    }

    static func persist(_ proposed: RuntimeWorkspaceContinuationAuthorization, task: AgentTask,
                        lease: RuntimeExecutionOwnerStore.Lease, context: ModelContext) throws {
        let store = RuntimeExecutionOwner.store(in: context)
        for source in proposed.sources { try store.retain(source.receipt) }
        try lease.saveWorkspaceContinuation(proposed)
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeWorkspaceContinuationAuthorized,
            payload: TaskEvent.payloadString([
                "request_id": proposed.requestID.uuidString,
                "source_event_id": proposed.sourceEventID.uuidString,
                "workspace_authorization_id": (proposed.inheritedAuthorizationID ?? (proposed.workspaceScope != nil ? proposed.requestID : nil))?.uuidString ?? "",
                "predecessor_executions": proposed.sources.map { $0.receipt.executionID.uuidString }.joined(separator: ",")
            ], fallback: "{}")))
        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
            modelContext: context, taskID: task.id,
            auditFields: ["operation": "authorize_workspace_continuation"])
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
        // Refresh an old task's grant for a genuinely new human turn: holders
        // admitted since its last turn must also be covered by the root decision.
        let inherited = try RuntimeWorkspaceContinuationScope.inherited(task: task, request: request,
            context: context, claims: claims, previous: previous)
        let authorizationID = inherited?.requestID ?? previous?.workspaceContinuationRequestID ?? request.id
        let savedAuthorization = try store.workspaceContinuation(requestID: authorizationID)
        guard let authorization = savedAuthorization ?? inherited else { return nil }
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
            let freshInherited = authorization.inheritedAuthorizationID != nil && authorization.requestID == request.id
                && isNewManualInstruction(request, task: task, previous: previous, context: context)
            guard freshInherited || (previous.workspaceContinuationRequestID == authorizationID
                && (resumesPreparation(previous, task: task, request: request, context: context)
                    || RuntimeCompletedUserTurnContinuation.permits(previous, task: task, request: request, context: context))) else { return nil }
        } else {
            guard isInitialInstruction(request, task: task, context: context) else { return nil }
        }
        let requested = claims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_continuation", sandboxEnforcement: .off)
        guard authorization.sources.flatMap({ $0.receipt.resourceClaims ?? [] }).allSatisfy({ held in
            requested.contains { $0.resourceKind == held.resourceKind && $0.resourceKey == held.resourceKey && $0.accessMode == held.accessMode }
        }) else { throw RuntimeExecutionOwnerStore.Failure.busy }
        return Admission(authorization: authorization, leases: try lockSources(authorization, store: store, context: context),
            needsPersistence: savedAuthorization == nil)
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
        guard let previous else { return isInitialInstruction(request, task: task, context: context) }
        return RuntimeExecutionAdmission.resolve(request: request, task: task) == .userInstruction
            && RuntimeCompletedUserTurnContinuation.hasCompletedTurn(previous, task: task, context: context)
    }

    static func isManualSource(_ request: TaskTurnRequest, task: AgentTask) -> Bool {
        if request.kind == .followUp {
            return TaskHistoryRead.event(id: request.sourceEventID, in: task)?.type == TaskEventTypes.Conversation.userMessage.rawValue
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
            leases.append(lease)
            let id = saved.taskID
            let candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
            guard let owner = candidates.first(where: { $0.persistentModelID == source.taskOwnerID }),
                  try RuntimeTaskOwnerJournal.read(task: owner, context: context) == saved,
                  RuntimeCompletedUserTurnContinuation.hasCompletedTurn(saved, task: owner, context: context) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            try requireNoKnownRemoteWork(task: owner, context: context)
        }
        return leases
    }

    private static func requireNoKnownRemoteWork(task: AgentTask, context: ModelContext) throws {
        for config in try RemoteWorkspaceJobRegistration.loadAll(task: task, context: context) {
            guard try RemoteWorkspaceJobStore(rootPath: config.recordRootPath).records().allSatisfy({ $0.status.isTerminal }) else {
                throw RuntimeExecutionOwnerStore.Failure.busy
            }
        }
    }
}
