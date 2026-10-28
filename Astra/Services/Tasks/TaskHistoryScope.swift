import Foundation
import SwiftData
import ASTRAModels

/// Portable UUIDs can identify several imported copies. A persisted row is
/// the read authority; legacy UUID-only callers must resolve unambiguously.
enum TaskHistoryScope {
    enum Failure: LocalizedError {
        case missingOwner
        case ambiguousOwner

        var errorDescription: String? {
            switch self {
            case .missingOwner: "This task's saved history is no longer available."
            case .ambiguousOwner: "Several imported tasks share this identifier. Select the specific task to read its history."
            }
        }
    }

    static func ownerID(
        taskID: UUID,
        ownerID: PersistentIdentifier?,
        in context: ModelContext
    ) throws -> PersistentIdentifier {
        if let ownerID {
            var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate {
                $0.persistentModelID == ownerID && $0.id == taskID
            })
            descriptor.fetchLimit = 1
            guard try context.fetch(descriptor).first != nil else { throw Failure.missingOwner }
            return ownerID
        }
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 2
        let tasks = try context.fetch(descriptor)
        guard let task = tasks.first else { throw Failure.missingOwner }
        guard tasks.count == 1 else { throw Failure.ambiguousOwner }
        return task.persistentModelID
    }
}
