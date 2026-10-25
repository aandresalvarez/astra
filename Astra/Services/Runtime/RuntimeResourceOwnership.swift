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

    static func claims(in store: RuntimeExecutionOwnerStore, context: ModelContext? = nil, excluding taskID: UUID? = nil) throws -> [TaskResourceLockClaim] {
        let records = try store.records()
        var claims: [TaskResourceLockClaim] = []
        for record in records where record.taskID != taskID && retainsResources(record) {
            if let captured = record.resourceClaims { claims += captured; continue }
            // Pre-upgrade receipts have no captured resource identity. Only a
            // verifiably ended owner can be omitted; unknown ownership blocks.
            let lease = try store.acquire(taskID: record.taskID)
            defer { withExtendedLifetime(lease) {} }
            guard record.canReplace || record.canBeginNewTurn else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        }
        if let context {
            let type = "runtime.execution_ownership"
            let events = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == type }))
            let known = Set(records.map(\.taskID))
            for event in events {
                guard let audit = try? JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: Data(event.payload.utf8)),
                      !known.contains(audit.taskID), audit.taskID != taskID else { continue }
                guard let captured = audit.resourceClaims else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
                claims += captured
            }
        }
        var seen: Set<TaskResourceLockClaim> = []
        return claims.filter { seen.insert($0).inserted }
    }

    static func permitsRelease(_ claims: [TaskResourceLockClaim], store: RuntimeExecutionOwnerStore,
                               context: ModelContext? = nil) throws -> Bool {
        let retained = Set(try self.claims(in: store, context: context))
        return !claims.contains(where: retained.contains)
    }
}
