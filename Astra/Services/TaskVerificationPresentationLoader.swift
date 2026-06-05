import Foundation

struct TaskVerificationLoadRequest: Hashable {
    let taskID: UUID
    let taskStatus: TaskStatus
    let taskUpdatedAt: Date
    let taskFolder: String
}

enum TaskVerificationPresentationLoader {
    static func presentation(isFinished: Bool, taskFolder: String) async -> TaskVerificationPresentation? {
        guard isFinished, !taskFolder.isEmpty else { return nil }
        let verification = await Task.detached(priority: .utility) {
            TaskContextStateManager.load(taskFolder: taskFolder)?.verification
        }.value
        return verification.map(TaskPresentationState.verificationPresentation(for:))
    }
}
