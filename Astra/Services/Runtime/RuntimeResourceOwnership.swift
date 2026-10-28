import Foundation
import SwiftData
import ASTRAModels

/// A projection of protected journals. Audit records can require a fence when
/// authority disappears, but can never authorize release or a new execution.
@MainActor
enum RuntimeResourceOwnership {
    nonisolated static func retainsResources(_ record: RuntimeExecutionOwnerRecord) -> Bool {
        record.resourcesReleased != true && !record.canRecoverPreparation
    }

    static func claims(in store: RuntimeExecutionOwnerStore, context: ModelContext? = nil, excluding taskID: UUID? = nil, excludingOwner: PersistentIdentifier? = nil) throws -> [TaskResourceLockClaim] {
        let records = try store.records()
        // Resolve legacy attribution without mutating it, including during queue
        // projection before the receiver acquires its real execution lease.
        var legacyOwners: [UUID: PersistentIdentifier] = [:]
        if let context {
            for record in records where record.taskOwnerID == nil {
                legacyOwners[record.taskID] = try? RuntimeTaskOwnerJournal.legacyOwner(record, context: context)
            }
        }
        var claims: [TaskResourceLockClaim] = []
        for record in records where !(record.taskID == taskID && (record.taskOwnerID ?? legacyOwners[record.taskID]) == excludingOwner) && retainsResources(record) {
            if let captured = record.resourceClaims { claims += captured; continue }
            // Pre-upgrade receipts have no captured resource identity. Only a
            // verifiably ended owner can be omitted; unknown ownership blocks.
            let lease = try store.acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
            defer { withExtendedLifetime(lease) {} }
            guard record.canReplace || record.canBeginNewTurn else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        }
        if let context {
            // A legacy current journal may have replaced a safely ended older
            // owner before persistent row attribution existed. Resolve the
            // current receipt to its unique local row, just as journal reads do;
            // older audit projections of that same row are not extra owners.
            // Ambiguous/imported rows keep their fallback fences.
            let type = "runtime.execution_ownership"
            let events = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == type }))
            let audits: [(TaskEvent, RuntimeExecutionOwnerRecord)] = events.compactMap { event in
                guard let record = try? JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: Data(event.payload.utf8)) else { return nil }
                return (event, record)
            }
            for (event, audit) in audits {
                guard !records.contains(where: { record in
                          guard record.taskID == audit.taskID, let eventTask = event.task,
                                let owner = record.taskOwnerID ?? legacyOwners[record.taskID] else { return false }
                          if owner == eventTask.persistentModelID { return true }
                          // A fork preserves its source's history verbatim. It
                          // cannot recreate old source reservations alongside
                          // that source's still-authoritative current journal.
                          // With no verified source journal the fallback stays.
                          return eventTask.id != audit.taskID && eventTask.forkedFromID == audit.taskID
                              && (audit.taskOwnerID == nil || audit.taskOwnerID == owner)
                              && (context.model(for: owner) as? AgentTask)?.id == audit.taskID
                              && audits.contains { native, receipt in
                                  native.task?.persistentModelID == owner && receipt == audit
                              }
                      }),
                      !(audit.taskID == taskID && event.task?.persistentModelID == excludingOwner) else { continue }
                guard let captured = audit.resourceClaims else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
                claims += captured
            }
        }
        var seen: Set<TaskResourceLockClaim> = []
        return claims.filter { seen.insert($0).inserted }
    }

    /// A settled worker can retire its process-local lease while its protected
    /// receipt continues to reserve every resource. Keeping both copies leaves
    /// an obsolete lease behind when a later turn replaces the current receipt.
    /// This does not certify tool cleanup or release durable ownership.
    static func canRetireLocalClaims(_ claims: [TaskResourceLockClaim], task: AgentTask,
                                     context: ModelContext) throws -> Bool {
        guard !claims.isEmpty, task.modelContext === context,
              let record = try RuntimeTaskOwnerJournal.read(task: task, context: context),
              retainsResources(record),
              RuntimeCompletedUserTurnContinuation.hasSettledTurn(record, task: task, context: context),
              let durable = record.resourceClaims else { return false }
        let lease = try RuntimeExecutionOwner.store(in: context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        defer { withExtendedLifetime(lease) {} }
        guard try RuntimeTaskOwnerJournal.read(task: task, context: context) == record else { return false }
        return claims.allSatisfy { claim in
            claim.taskID == task.id && durable.contains { held in
                held.taskID == task.id && held.resourceKind == claim.resourceKind
                    && held.resourceKey == claim.resourceKey
                    && (held.accessMode == .write || claim.accessMode == .readOnly)
            }
        }
    }

    static func permitsRelease(_ claims: [TaskResourceLockClaim], store: RuntimeExecutionOwnerStore,
                               context: ModelContext? = nil) throws -> Bool {
        let retained = Set(try self.claims(in: store, context: context))
        return !claims.contains(where: retained.contains)
    }
}
