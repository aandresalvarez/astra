import Foundation
import SwiftData
import ASTRAModels

@MainActor
enum TaskStorageBindingService {
    @discardableResult
    static func bind(task: AgentTask, scope: TaskExecutionResourceScope, modelContext: ModelContext) throws -> TaskEvent? {
        let storages = scope.resources.filter { $0.role == .taskStorage }
        guard scope.isValid, storages.count <= 1 else { throw TaskStorageBinding.BindingError.invalid }
        guard let storage = storages.first else {
            guard scope.workspacePath.isEmpty else { throw TaskStorageBinding.BindingError.invalid }
            return nil
        }
        guard scope.coversWrite(to: storage.path) else { throw TaskStorageBinding.BindingError.invalid }
        if let binding = try TaskStorageBinding.load(for: task) {
            guard binding.path == storage.canonicalPath else { throw TaskStorageBinding.BindingError.relocationRequired }
            return nil
        }
        let event = TaskEvent.structuredPayloadEvent(task: task, type: TaskStorageBinding.eventType,
            payload: TaskStorageBinding(taskID: task.id, path: storage.path, workspacePath: scope.workspacePath))
        modelContext.insert(event)
        return event
    }
}
