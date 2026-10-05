import Foundation
import ASTRAModels
import ASTRAPersistence

/// A derived invocation value. The request/checkpoint remains the durable owner.
struct TaskExecutionContext: Sendable {
    let taskID: UUID
    let workingDirectory: String
    let taskFolder: String
    private let authority: Authority

    private enum Authority: Sendable {
        case accepted(TaskExecutionResourceScope)
        case legacy
    }

    init(taskID: UUID, acceptedScope: TaskExecutionResourceScope, workingDirectory: String? = nil) {
        self.taskID = taskID
        self.workingDirectory = workingDirectory ?? acceptedScope.workingDirectory
        taskFolder = acceptedScope.resources.first { $0.role == .taskStorage }?.canonicalPath ?? ""
        authority = .accepted(acceptedScope)
    }

    private init(taskID: UUID, workingDirectory: String, taskFolder: String) {
        self.taskID = taskID
        self.workingDirectory = workingDirectory
        self.taskFolder = taskFolder
        authority = .legacy
    }

    /// Only legacy/direct entry points may capture live configuration.
    @MainActor
    static func legacy(task: AgentTask, workingDirectory: String? = nil) -> Self {
        if let scope = task.acceptedResourceScope { return .init(taskID: task.id, acceptedScope: scope) }
        let access = TaskWorkspaceAccess(task: task)
        return .init(taskID: task.id, workingDirectory: workingDirectory ?? access.codeWorkingDirectory,
            taskFolder: access.taskFolder)
    }

    var resourceScope: TaskExecutionResourceScope? {
        if case .accepted(let scope) = authority { return scope }
        return nil
    }

    var isValid: Bool {
        guard let scope = resourceScope else { return true }
        return scope.isValid && TaskExecutionResourceScope.canonicalPath(workingDirectory)
            == TaskExecutionResourceScope.canonicalPath(scope.workingDirectory)
    }

    func validate(task: AgentTask) throws {
        guard task.id == taskID, isValid else { throw ContextError.invalid }
        let binding = try TaskStorageBinding.load(for: task)
        if let binding, resourceScope != nil, binding.path != taskFolder { throw ContextError.invalid }
        if let scope = resourceScope, !taskFolder.isEmpty {
            guard scope.coversWrite(to: taskFolder) else { throw ContextError.invalid }
        }
    }

    enum ContextError: LocalizedError {
        case invalid

        var errorDescription: String? {
            "The accepted execution context is invalid. Restore its resource locations or submit a new turn."
        }
    }
}
