import Foundation
import ASTRAModels

struct TaskVerificationLoadRequest: Hashable {
    let taskID: UUID
    let taskStatus: TaskStatus
    let taskUpdatedAt: Date
    let taskFolder: String
}

struct TaskVerificationStateReader: Sendable {
    private let loadVerification: @Sendable (String) -> TaskContextState.Verification?

    init(loadVerification: @escaping @Sendable (String) -> TaskContextState.Verification?) {
        self.loadVerification = loadVerification
    }

    func verification(taskFolder: String) -> TaskContextState.Verification? {
        loadVerification(taskFolder)
    }

    static let taskContextState = TaskVerificationStateReader { taskFolder in
        TaskContextStateManager.load(taskFolder: taskFolder)?.verification
    }
}

enum TaskVerificationPresentationLoader {
    static func presentation(
        isFinished: Bool,
        taskFolder: String,
        stateReader: TaskVerificationStateReader = .taskContextState
    ) async -> TaskVerificationPresentation? {
        guard isFinished, !taskFolder.isEmpty else { return nil }
        let verification = await Task.detached(priority: .utility) {
            stateReader.verification(taskFolder: taskFolder)
        }.value
        return verification.map(TaskPresentationState.verificationPresentation(for:))
    }
}
