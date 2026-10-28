import Foundation
import SwiftData
import ASTRAModels

/// Attributes protected receipts to a local row. Portable task/run UUIDs and
/// imported audit text cannot authorize borrowing another copy's execution.
@MainActor
enum RuntimeTaskOwnerJournal {
    static func read(task: AgentTask, context: ModelContext) throws -> RuntimeExecutionOwnerRecord? {
        let store = RuntimeExecutionOwner.store(in: context)
        let scoped = try store.read(taskID: task.id, taskOwnerID: task.persistentModelID)
        guard let legacy = try store.read(taskID: task.id) else { return scoped }
        let owner = try legacyOwner(legacy, context: context)
        guard owner == task.persistentModelID else { return scoped }
        guard scoped == nil else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        return legacy
    }

    static func acquire(task: AgentTask, context: ModelContext) throws -> RuntimeExecutionOwnerStore.Lease {
        if task.persistentModelID.storeIdentifier == nil {
            guard task.modelContext === context else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
            try context.save()
        }
        let store = RuntimeExecutionOwner.store(in: context)
        let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
        guard let legacy = try store.read(taskID: task.id) else { return lease }
        let owner = try legacyOwner(legacy, context: context)
        if owner == task.persistentModelID { try lease.bindLegacy(legacy) }
        return lease
    }

    static func legacyOwner(_ record: RuntimeExecutionOwnerRecord, context: ModelContext) throws -> PersistentIdentifier {
        if let owner = record.taskOwnerID { return owner }
        let taskID = record.taskID
        let tasks = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
        let owners = tasks.filter { task in
            TaskHistoryRead.events(for: task, ofTypes: [TaskEventTypes.System.runtimeExecutionOwnership.rawValue]).contains { event in
                guard event.type == TaskEventTypes.System.runtimeExecutionOwnership.rawValue,
                      let audit = try? JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: Data(event.payload.utf8)) else { return false }
                return audit.taskID == record.taskID && audit.ownerID == record.ownerID
                    && audit.executionID == record.executionID
                    && (audit.taskOwnerID == nil || audit.taskOwnerID == task.persistentModelID)
            }
        }
        guard owners.count == 1, let owner = owners.first else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        return owner.persistentModelID
    }
}
