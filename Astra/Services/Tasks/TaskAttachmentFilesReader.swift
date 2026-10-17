import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

/// Reads attachment history independently of the bounded transcript window.
/// Call off-main with a fresh context; events remain the durable owner.
enum TaskAttachmentFilesReader {
    static func paths(taskID: UUID, container: ModelContainer) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            try paths(taskID: taskID, modelContext: ModelContext(container))
        }.value
    }

    static func paths(taskID: UUID, modelContext: ModelContext) throws -> [String] {
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
