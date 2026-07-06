import Foundation
import ASTRAModels

struct TaskMissionControlSnapshot {
    let taskFolder: String
    let state: TaskContextState?
    let presentation: MissionControlPresentation?
    let verificationLoadRequest: TaskVerificationLoadRequest?

    @MainActor
    static func build(
        task: AgentTask,
        planState: TaskPlanState,
        isFinished: Bool
    ) -> TaskMissionControlSnapshot {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = folder.isEmpty ? nil : TaskContextStateManager.load(taskFolder: folder)
        let request = verificationLoadRequest(
            task: task,
            taskFolder: folder,
            isFinished: isFinished
        )

        return TaskMissionControlSnapshot(
            taskFolder: folder,
            state: state,
            presentation: MissionControlPresentation.build(
                task: task,
                planState: planState,
                state: state
            ),
            verificationLoadRequest: request
        )
    }

    private static func verificationLoadRequest(
        task: AgentTask,
        taskFolder: String,
        isFinished: Bool
    ) -> TaskVerificationLoadRequest? {
        guard isFinished, !taskFolder.isEmpty else { return nil }
        return TaskVerificationLoadRequest(
            taskID: task.id,
            taskStatus: task.status,
            taskUpdatedAt: task.updatedAt,
            taskFolder: taskFolder
        )
    }
}
