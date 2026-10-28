import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A remembered human decision for one persistent workspace and exact resource
/// scope (or a narrower subset). It never certifies cleanup. Only completed executions in that decision's
/// lineage are eligible; an unrelated owner or changed predecessor stays fenced.
@MainActor
enum RuntimeWorkspaceContinuationScope {
    static func inherited(task: AgentTask, request: TaskTurnRequest, context: ModelContext,
                          claims: [TaskResourceLockClaim]?, previous: RuntimeExecutionOwnerRecord?) throws -> RuntimeWorkspaceContinuationAuthorization? {
        guard RuntimeWorkspaceContinuation.isNewManualInstruction(request, task: task, previous: previous, context: context),
              let workspace = task.workspace else { return nil }
        let store = RuntimeExecutionOwner.store(in: context)
        let roots = try store.workspaceAuthorizations(workspaceOwnerID: workspace.persistentModelID).filter {
            guard let scope = $0.workspaceScope else { return false }
            return matches(scope, task: task, request: request, claims: claims)
        }
        guard !roots.isEmpty else { return nil }
        let requested = claims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "workspace_continuation", sandboxEnforcement: .off)
        let held = try RuntimeResourceOwnership.claims(in: store, context: context, excluding: task.id, excludingOwner: task.persistentModelID)
        guard !TaskExecutionResourceBroker.canAcquire(requested, active: held) else { return nil }
        var proposed = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: context, previous: previous)
        for root in roots {
            proposed.inheritedAuthorizationID = root.requestID
            if try validates(proposed, task: task, request: request, context: context, claims: claims, previous: previous) {
                return proposed
            }
        }
        return nil
    }

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
        let receiver = previous.map { RuntimeWorkspaceContinuationAuthorization.Source(taskOwnerID: task.persistentModelID, receipt: $0) }
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
