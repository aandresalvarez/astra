import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

/// A read belongs to a persisted model, not just its importable UUID.
struct TaskAttachmentHistoryScope: Hashable, Sendable {
    let taskID: UUID
    let ownerID: PersistentIdentifier

    init(task: AgentTask) {
        taskID = task.id
        ownerID = task.persistentModelID
    }

    var signature: String { "\(taskID.uuidString)|\(ownerID)" }
}

/// Reads attachment history independently of the bounded transcript window.
/// Call off-main with a fresh context; events remain the durable owner.
enum TaskAttachmentFilesReader {
    static func paths(scope: TaskAttachmentHistoryScope, container: ModelContainer) async throws -> [String] {
        let read = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try paths(scope: scope, modelContext: context)
        }
        return try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            read.cancel()
        }
    }

    static func paths(scope: TaskAttachmentHistoryScope, modelContext: ModelContext) throws -> [String] {
        let taskID = scope.taskID
        let messageType = TaskEventTypes.Conversation.userMessage.rawValue
        let planningType = TaskPlanConversationEventTypes.userMessage
        let recordType = TaskEventTypes.Conversation.attachments.rawValue
        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate {
                $0.task?.id == taskID && ($0.type == messageType || $0.type == planningType || $0.type == recordType)
            },
            sortBy: [SortDescriptor(\TaskEvent.timestamp)]
        )
        var facts: [TaskAttachmentLedger.EventFacts] = []
        try modelContext.enumerate(descriptor, batchSize: 128) { event in
            try Task.checkCancellation()
            guard !event.isDeleted, let owner = event.task, !owner.isDeleted,
                  owner.persistentModelID == scope.ownerID else { return }
            // Keep identities and attachment metadata, never whole user texts.
            let payload = event.type == recordType ? event.payload
                : TaskAttachmentBlock.message("", attaching: TaskAttachmentBlock.paths(in: event.payload))
            facts.append(.init(id: event.id, type: event.type, payload: payload, timestamp: event.timestamp))
        }
        var seen: Set<String> = []
        return TaskAttachmentLedger.entries(in: facts).compactMap { entry in
            let path = TaskFileIndex.normalizedPath(entry.path)
            return path.hasPrefix("/") && seen.insert(path).inserted ? path : nil
        }
    }

    static func merging(paths: [String], with items: [TaskFileItem]) -> [TaskFileItem] {
        var seen = Set(items.map { TaskFileIndex.normalizedPath($0.path) })
        let attachments = paths.compactMap { path -> TaskFileItem? in
            guard seen.insert(path).inserted else { return nil }
            var directory = ObjCBool(false)
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            return TaskFileIndex.fileItem(path: path, isDirectory: directory.boolValue, source: "attached")
        }
        return items + attachments
    }
}
