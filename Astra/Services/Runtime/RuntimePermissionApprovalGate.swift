import Foundation
import ASTRAModels

/// Decides whether a failed run should stop and ask the user to approve wider
/// runtime permissions, or simply report the failure.
///
/// It lives on its own because getting it wrong is not a cosmetic mistake. An
/// approval card is a promise: approve this and the run can continue. When the
/// card is offered for something an approval cannot reach, the user has no way
/// out except to stop trying — task 5FB5E95B was approved five times against a
/// Vertex `403 Permission denied on resource project …`, and each approval
/// produced the identical call and the identical 403.
enum RuntimePermissionApprovalGate {
    @MainActor
    static func shouldPause(
        failureDiagnostic: AgentRuntimeFailureDiagnostic?,
        task: AgentTask,
        run: TaskRun
    ) -> Bool {
        // The keyword-classified branch also asks whether approving would
        // change anything. `.permissionDenied` covers both a local prompt ASTRA
        // can widen and the provider refusing the call outright; only the first
        // is worth a card.
        if let failureDiagnostic,
           failureDiagnostic.category == .permissionDenied,
           failureDiagnostic.isApprovableRuntimePermission {
            return true
        }
        // A runtime that emitted a structured permission event is unambiguous:
        // it asked for something. That path is untouched by the check above.
        return task.events.contains { event in
            event.type == "permission.denied" && event.run?.id == run.id
        }
    }
}
