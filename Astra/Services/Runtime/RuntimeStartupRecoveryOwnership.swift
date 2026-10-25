import Foundation
import SwiftData

/// Startup reconciliation holds the same per-task kernel lease through its
/// final save. A second app cannot terminalize another owner's live work.
@MainActor
final class RuntimeStartupRecoveryOwnership {
    private let store: RuntimeExecutionOwnerStore
    private var leases: [UUID: RuntimeExecutionOwnerStore.Lease] = [:]
    init(context: ModelContext) { store = RuntimeExecutionOwner.store(in: context) }
    func claim(_ taskID: UUID) -> Bool {
        if leases[taskID] != nil { return true }
        guard let lease = try? store.acquire(taskID: taskID) else { return false }
        leases[taskID] = lease
        return true
    }
}
