import Foundation
import SwiftData

enum TaskRuntimePermissionApprovalAction: Equatable {
    case approveSimilarForTask
    case approveOnce
}

enum TaskRuntimePermissionActionHandler {
    static func approvalAction(
        canApproveSimilarForTask: Bool,
        hasTaskQueue: Bool
    ) -> TaskRuntimePermissionApprovalAction {
        canApproveSimilarForTask && hasTaskQueue ? .approveSimilarForTask : .approveOnce
    }

    @MainActor
    static func approveSimilarRuntimePermissionForTask(
        _ task: AgentTask,
        modelContext: ModelContext,
        taskQueue: TaskQueue?,
        canApproveSimilarForTask: Bool
    ) -> TaskRuntimePermissionApprovalAction {
        let action = approvalAction(
            canApproveSimilarForTask: canApproveSimilarForTask,
            hasTaskQueue: taskQueue != nil
        )
        guard action == .approveSimilarForTask,
              let taskQueue else {
            return action
        }

        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: taskQueue)
        coordinator.approveSimilarRuntimePermissionForTask(task)
        return action
    }
}
