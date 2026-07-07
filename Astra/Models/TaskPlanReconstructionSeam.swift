import Foundation
import os

// Added as part of Track A4 (ASTRAPersistence extraction) so
// `Astra/Services/Persistence/TaskActiveObjectiveResolver.swift`,
// `OriginalGoalDeliveryClassifier.swift`, `TaskContextStateManager.swift`,
// and `TaskObjectiveAssessmentPivotReconciler.swift` can reconstruct plan
// state from a task's event history without depending on
// `Astra/Services/Tasks/TaskPlanService.swift` (the ~1,150-line app-side
// plan-reconstruction engine, used throughout Views/Runtime/Validation and
// far too large/coupled to move).
//
// Lives in `ASTRAModels`, not `ASTRACore` - unlike every other seam so far,
// this protocol's signature is inherently shaped around Models types
// (`AgentTask`, `TaskPlanState`, `TaskPlanPayload`, `TaskPlanPayloadStep`):
// reconstructing plan state from a task's event history isn't expressible
// in primitives without also smuggling `TaskEvent` across the boundary,
// which is just as much a Models type as `AgentTask` itself. `ASTRACore`
// can never import `ASTRAModels`, but `ASTRAModels` can freely reference its
// own types, so the seam belongs here instead - the same reasoning that
// already put `AgentTaskForkService` in this target rather than `ASTRACore`.
//
// Follows the exact registration pattern in `RuntimeSeams.swift`: a public
// protocol + an `OSAllocatedUnfairLock`-backed static registry with
// `.register(_:)` and a fail-fast `.required` accessor, wired up from
// `RuntimeSeamRegistration.registerAll()`.
public protocol TaskPlanReconstructing: Sendable {
    static func reconstruct(for task: AgentTask) -> TaskPlanState
    static func nextExecutableStep(in plan: TaskPlanPayload) -> TaskPlanPayloadStep?
}

public enum TaskPlanReconstructionSeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskPlanReconstructing.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ reconstructor: any TaskPlanReconstructing.Type) {
        storage.withLock { $0 = reconstructor }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    public static var required: any TaskPlanReconstructing.Type {
        guard let reconstructor = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskPlanReconstructionSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return reconstructor
    }
}
