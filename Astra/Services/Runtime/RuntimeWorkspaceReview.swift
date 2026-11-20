import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// "Review workspace": what still holds the folders a waiting request
/// names, asked now of the one release rule, and a person's decision to
/// start past what that rule cannot answer.
///
/// The decision ends the holders' reservations
/// (`RuntimeReservationRelease.release(_:decidedFor:)`), so the waiting
/// request is then admitted like any other. Nothing is remembered and
/// nothing is inherited: the next task meets no holder to be asked about.
/// A holder that is itself still at work cannot be started past. A process
/// that a finished holder left behind can, once the dialog has named it.
///
/// Design: docs/specs/2026-11-18-workspace-reservation-and-parallelism.md, B.
@MainActor
enum RuntimeWorkspaceReview {
    struct Holder: Equatable {
        let taskID: UUID
        let title: String
        let receipt: RuntimeExecutionOwnerRecord
        /// What the release rule answered for this holder. Never empty.
        let blockers: [RuntimeReservationRelease.Blocker]
        /// The holder's claims that the request waits for.
        let claims: [TaskResourceLockClaim]
        /// Everything else it reserves. A decision frees those with it.
        let otherClaims: [TaskResourceLockClaim]

        var isActive: Bool { blockers.contains(where: \.holderIsActive) }
    }

    struct Review: Equatable {
        let requestID: UUID
        let holders: [Holder]
        /// False while any holder is itself still at work.
        var canStart: Bool { !holders.contains(where: \.isActive) }
    }

    /// Only a request a person wrote can receive the decision. A schedule,
    /// a chained task and a plan step wait for the rule alone.
    static func qualifies(_ request: TaskTurnRequest, task: AgentTask, context: ModelContext) -> Bool {
        task.isLive && task.modelContext === context && request.modelContext === context
            && request.state.isActive && request.taskID == task.id
            && (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID
            && RuntimeWorkspaceContinuation.isManualSource(request, task: task)
    }

    /// Advisory: `start` asks every holder again under its lease. Holders the
    /// rule can answer are released here, with no decision. Returns nil when
    /// no saved reservation holds the request any more.
    static func preview(task: AgentTask, request: TaskTurnRequest, context: ModelContext,
                        bootedAt: Date? = ProviderSharedStateReadObservation.hostBootTime(),
                        observe: (RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation
                            = { RuntimeExecutionLocalSurvivors.observe($0) }) throws -> Review? {
        guard qualifies(request, task: task, context: context) else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let store = RuntimeExecutionOwner.store(in: context)
        try RuntimeReservationRelease.reconcile(in: store, context: context, bootedAt: bootedAt, observe: observe)
        let requested = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_review", sandboxEnforcement: .off)
        let held = try RuntimeResourceOwnership.claims(in: store, context: context, excluding: task.id, excludingOwner: task.persistentModelID)
        let conflicts = held.filter { !TaskExecutionResourceBroker.canAcquire(requested, active: [$0]) }
        guard !requested.isEmpty, !conflicts.isEmpty else { return nil }
        var holders: [Holder] = []
        for record in try store.records() where RuntimeResourceOwnership.retainsResources(record)
            && record.resourceClaims?.contains(where: conflicts.contains) == true {
            // A copy of this task under the same ID is not another task to decide about.
            guard record.taskID != task.id,
                  let owner = try RuntimeReservationRelease.owner(of: record, context: context) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let blockers = try RuntimeReservationRelease.standing(record, task: owner, store: store, context: context,
                bootedAt: bootedAt, observe: observe)
            // The rule would end it: nothing to decide, and it is released on the next pass.
            guard !blockers.isEmpty else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let reserved = (record.resourceClaims ?? []).filter { $0.resourceKind != .nativeSession }
            holders.append(Holder(taskID: owner.id, title: owner.title, receipt: record, blockers: blockers,
                claims: reserved.filter(conflicts.contains), otherClaims: reserved.filter { !conflicts.contains($0) }))
        }
        // A fence that no readable receipt accounts for cannot be decided about.
        guard Set(conflicts).isSubset(of: Set(holders.flatMap(\.claims))) else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        return Review(requestID: request.id, holders: holders.sorted { $0.taskID.uuidString < $1.taskID.uuidString })
    }

    /// The person chose "Start now" on `reviewed`. Anything that changed
    /// since the dialog opened refuses, and they are asked again. Returns
    /// without a decision when nothing holds the request any more.
    static func start(_ reviewed: Review, task: AgentTask, request: TaskTurnRequest, context: ModelContext,
                      bootedAt: Date? = ProviderSharedStateReadObservation.hostBootTime(),
                      observe: (RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation
                          = { RuntimeExecutionLocalSurvivors.observe($0) }) throws {
        guard reviewed.requestID == request.id else { throw RuntimeExecutionOwnerStore.Failure.busy }
        guard let fresh = try preview(task: task, request: request, context: context, bootedAt: bootedAt, observe: observe) else { return }
        guard fresh == reviewed, fresh.canStart else { throw RuntimeExecutionOwnerStore.Failure.busy }
        let store = RuntimeExecutionOwner.store(in: context)
        let admission = try store.acquireAdmission()
        defer { withExtendedLifetime(admission) {} }
        try RuntimeReservationRelease.release(fresh.holders.map { .init(receipt: $0.receipt, blockers: $0.blockers) },
            decidedFor: request.id, store: store, context: context, bootedAt: bootedAt, observe: observe)
        let folders = RuntimeWorkspaceReviewWording.folders(fresh.holders.flatMap { $0.claims + $0.otherClaims })
        for holder in fresh.holders {
            guard let owner = try RuntimeReservationRelease.owner(of: holder.receipt, context: context) else { continue }
            context.insert(TaskEvent(task: owner, eventType: TaskEventTypes.System.info,
                payload: RuntimeWorkspaceReviewWording.holderNote(folders: folders)))
        }
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeWorkspaceContinuationAuthorized,
            payload: TaskEvent.payloadString([
                "request_id": request.id.uuidString,
                "source_event_id": request.sourceEventID.uuidString,
                "predecessor_executions": fresh.holders.map { $0.receipt.executionID.uuidString }.joined(separator: ","),
                "named": fresh.holders.flatMap { $0.blockers.flatMap(\.auditNames) }.joined(separator: ",")
            ], fallback: "{}")))
        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
            modelContext: context, taskID: task.id,
            auditFields: ["operation": "start_past_workspace_holders"])
    }
}
