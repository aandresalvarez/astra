import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A decision an earlier build remembered for one workspace and resource
/// scope. Nothing is remembered any more and no new request resolves one
/// ("Review workspace" ends the holders' reservations instead). This still
/// validates a request that was saved under such a decision before the change:
/// only the exact receipts the person acknowledged and completed executions
/// in that decision's lineage are eligible.
@MainActor
enum RuntimeWorkspaceContinuationScope {
    static func validates(_ authorization: RuntimeWorkspaceContinuationAuthorization, task: AgentTask,
                          request: TaskTurnRequest, context: ModelContext,
                          claims: [TaskResourceLockClaim]?, previous: RuntimeExecutionOwnerRecord?) throws -> Bool {
        let store = RuntimeExecutionOwner.store(in: context)
        guard let rootID = authorization.inheritedAuthorizationID else {
            guard let scope = authorization.workspaceScope else { return true } // old request-only decision
            return matches(scope, task: task, request: request, claims: claims)
        }
        guard let root = try store.workspaceContinuation(requestID: rootID),
              root.inheritedAuthorizationID == nil, let scope = root.workspaceScope,
              matches(scope, task: task, request: request, claims: claims),
              let originalOwner = try owner(of: root, context: context),
              originalOwner.workspace?.persistentModelID == scope.workspaceOwnerID,
              originalOwner.workspace?.id == scope.workspaceID,
              let original = try TaskTurnRequestRepository.request(id: root.requestID, in: context),
              original.state == .completed else { return false }
        // The receiving task's own receipt is acknowledged only while it still
        // reserves something. Once its reservation ended there is nothing of
        // its own left for the decision to cover.
        let receiver = previous.flatMap { RuntimeResourceOwnership.retainsResources($0)
            ? RuntimeWorkspaceContinuationAuthorization.Source(taskOwnerID: task.persistentModelID, receipt: $0) : nil }
        for source in authorization.sources + [receiver].compactMap({ $0 }) {
            let receipt = source.receipt
            // Exact acknowledged receipts remain valid, including legacy owners.
            if root.sources.contains(where: { original in
                guard original.taskOwnerID == source.taskOwnerID else { return false }
                var acknowledged = original.receipt
                // A verified legacy attribution is the only compatible metadata
                // difference; identity, limits, claims and stop proof stay exact.
                if acknowledged.taskOwnerID == nil { acknowledged.taskOwnerID = receipt.taskOwnerID }
                return acknowledged == receipt
            }) { continue }
            // New receipts must come from a task actually admitted through this
            // same protected decision, never from copied event JSON or a UUID alone.
            guard let sourceID = receipt.workspaceContinuationRequestID,
                  let grant = try store.workspaceContinuation(requestID: sourceID),
                  grant.requestID == rootID || grant.inheritedAuthorizationID == rootID,
                  grant.taskID == receipt.taskID, grant.taskOwnerID == source.taskOwnerID,
                  receipt.taskOwnerID == source.taskOwnerID,
                  let sourceOwner = try owner(of: grant, context: context),
                  sourceOwner.workspace?.persistentModelID == scope.workspaceOwnerID,
                  sourceOwner.workspace?.id == scope.workspaceID else { return false }
            // The person saw the receipts they acknowledged, failed turns
            // included. A holder that failed afterwards is new uncertainty
            // and needs their own decision. The receiving task's receipt is
            // judged by `isNewManualInstruction`, not here.
            guard source.taskOwnerID == task.persistentModelID
                || RuntimeCompletedUserTurnContinuation.hasCompletedTurn(receipt, task: sourceOwner, context: context) else { return false }
        }
        return true
    }

    private static func matches(_ scope: RuntimeWorkspaceContinuationAuthorization.WorkspaceScope,
                                task: AgentTask, request: TaskTurnRequest,
                                claims: [TaskResourceLockClaim]?) -> Bool {
        guard let workspace = task.workspace, workspace.id == scope.workspaceID,
              workspace.persistentModelID == scope.workspaceOwnerID else { return false }
        let requested = claims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_continuation", sandboxEnforcement: .off)
        func equalResource(_ a: TaskResourceLockClaim, _ b: TaskResourceLockClaim) -> Bool {
            a.resourceKind == b.resourceKind && a.resourceKey == b.resourceKey && a.accessMode == b.accessMode
        }
        return !requested.isEmpty && !scope.claims.isEmpty
            && requested.allSatisfy { item in scope.claims.contains { equalResource(item, $0) } }

    }

    private static func owner(of grant: RuntimeWorkspaceContinuationAuthorization, context: ModelContext) throws -> AgentTask? {
        let id = grant.taskID
        let candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
        guard let owner = candidates.first(where: { $0.persistentModelID == grant.taskOwnerID }),
              let request = try TaskTurnRequestRepository.request(id: grant.requestID, in: context),
              request.sourceEventID == grant.sourceEventID,
              (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == owner.persistentModelID,
              RuntimeWorkspaceContinuation.isManualSource(request, task: owner) else { return nil }
        return owner
    }
}
