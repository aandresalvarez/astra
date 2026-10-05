import Foundation
import SwiftData
import ASTRACore

/// Task storage is bound by an accepted request, not by subsequent workspace edits.
public struct TaskStorageBinding: Codable, Equatable, Sendable {
    public static let eventType = "task.storage.bound"
    public let version: Int
    public let taskID: UUID
    public let path: String
    public let workspacePath: String

    public init(taskID: UUID, path: String, workspacePath: String) {
        version = 1
        self.taskID = taskID
        self.path = TaskExecutionResourceScope.canonicalPath(path)
        self.workspacePath = workspacePath.isEmpty ? "" : TaskExecutionResourceScope.canonicalPath(workspacePath)
    }

    public static func load(for task: AgentTask) throws -> Self? {
        let event: TaskEvent?
        if let context = task.modelContext {
            let taskID = task.id
            let type = eventType
            var query = FetchDescriptor<TaskEvent>(
                predicate: #Predicate { $0.task?.id == taskID && $0.type == type },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse), SortDescriptor(\.id, order: .reverse)])
            query.fetchLimit = 1
            event = try context.fetch(query).first
        } else {
            event = task.events.filter({ !$0.isDeleted && $0.type == eventType })
                .max(by: { $0.timestamp < $1.timestamp })
        }
        guard let event else { return nil }
        let binding = try JSONDecoder().decode(Self.self, from: Data(event.payload.utf8))
        guard binding.version == 1, binding.taskID == task.id, binding.path.hasPrefix("/"),
              binding.path != "/", binding.path == TaskExecutionResourceScope.canonicalPath(binding.path) else {
            throw BindingError.invalid
        }
        return binding
    }

    public enum BindingError: LocalizedError {
        case invalid, relocationRequired

        public var errorDescription: String? {
            switch self {
            case .invalid: "The task's accepted storage binding is invalid. Restore its original folder before continuing."
            case .relocationRequired: "Task storage cannot move implicitly. Migrate the task files explicitly before accepting a different storage location."
            }
        }
    }
}
