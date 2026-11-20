import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Writes the per-request workspace decision an earlier build saved when a
/// person chose "Continue workspace". No build writes one any more: "Review
/// workspace" ends the holders' reservations instead
/// (`RuntimeWorkspaceReview`). A decision already on disk stays valid for its
/// request until its holders release, and these fixtures keep that reading
/// side covered.
@MainActor
enum RuntimeWorkspaceLegacyDecision {
    /// The decision as the earlier build composed it: every holder whose
    /// claims conflict with the request, the claims of each that the request
    /// names, and optionally the SSH jobs the person reviewed.
    static func compose(task: AgentTask, request: TaskTurnRequest, context: ModelContext,
                        previous: RuntimeExecutionOwnerRecord? = nil,
                        reviewSSHJobs: Bool = false) throws -> RuntimeWorkspaceContinuationAuthorization {
        let store = RuntimeExecutionOwner.store(in: context)
        let requested = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_continuation", sandboxEnforcement: .off)
        let held = try RuntimeResourceOwnership.claims(in: store, context: context, excluding: task.id, excludingOwner: task.persistentModelID)
        let conflicts = held.filter { !TaskExecutionResourceBroker.canAcquire(requested, active: [$0]) }
        var sources: [RuntimeWorkspaceContinuationAuthorization.Source] = []
        for record in try store.records() where record.resourceClaims?.contains(where: conflicts.contains) == true {
            let owner = try #require(try RuntimeReservationRelease.owner(of: record, context: context))
            let claims = (record.resourceClaims ?? []).filter { $0.resourceKind == .workspace || $0.resourceKind == .gitCommonDirectory }
            let reviewed = claims.filter { claim in requested.contains { TaskExecutionResourceBroker.names($0, resourceOf: claim) } }
            let jobs = reviewSSHJobs
                ? try RuntimeWorkspaceRemoteJobs.inventory(task: owner, owner: record, context: context).filter { !$0.status.isTerminal } : []
            sources.append(.init(taskOwnerID: owner.persistentModelID, receipt: record,
                reviewedSSHJobs: jobs.isEmpty ? nil : jobs, reviewedClaims: reviewed))
        }
        return .init(taskID: task.id, taskOwnerID: task.persistentModelID, requestID: request.id, sourceEventID: request.sourceEventID,
            approvedAt: Date(), sources: sources.sorted { $0.receipt.taskID.uuidString < $1.receipt.taskID.uuidString },
            beneficiaryReceiptDigest: try previous.map(RuntimeExecutionOwnerStore.receiptDigest))
    }

    /// Saves `decision` the way the earlier build did: each holder's receipt
    /// archived, then the protected entries under the receiving task's lease.
    static func write(_ decision: RuntimeWorkspaceContinuationAuthorization, task: AgentTask, context: ModelContext) throws {
        let store = RuntimeExecutionOwner.store(in: context)
        let admission = try store.acquireAdmission()
        let lease = try RuntimeTaskOwnerJournal.acquire(task: task, context: context)
        defer { withExtendedLifetime((admission, lease)) {} }
        for source in decision.sources { try store.retain(source.receipt) }
        try lease.saveWorkspaceContinuation(decision)
        try context.save()
    }

    /// Composes and saves. `rememberWorkspace` adds the workspace scope an
    /// earlier build stored when the person's answer was remembered.
    @discardableResult
    static func save(task: AgentTask, request: TaskTurnRequest, context: ModelContext,
                     previous: RuntimeExecutionOwnerRecord? = nil, reviewSSHJobs: Bool = false,
                     rememberWorkspace: Bool = false) throws -> RuntimeWorkspaceContinuationAuthorization {
        var decision = try compose(task: task, request: request, context: context, previous: previous, reviewSSHJobs: reviewSSHJobs)
        if rememberWorkspace {
            let workspace = try #require(task.workspace)
            decision.workspaceScope = .init(workspaceID: workspace.id, workspaceOwnerID: workspace.persistentModelID,
                claims: TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
                    runMode: "workspace_continuation", sandboxEnforcement: .off))
        }
        try write(decision, task: task, context: context)
        return decision
    }
}
