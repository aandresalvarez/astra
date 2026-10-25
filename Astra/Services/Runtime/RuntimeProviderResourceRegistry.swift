import Foundation

/// Registered store roots are a cache of locations, not release authority.
/// Every acquisition reads durable receipts again, including after restart.
enum RuntimeProviderResourceRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var roots: Set<URL> = []
    static func register(_ root: URL) { _ = lock.withLock { roots.insert(root) } }
    /// Retire only after a store's producers have joined, before deleting it.
    /// Joining the scan lock prevents readers from traversing partially removed files.
    static func unregister(_ root: URL) { _ = lock.withLock { roots.remove(root) } }
    static func assertAvailable(_ key: AgentRuntimeSharedStateKey, ownerID: UUID?) throws {
        try lock.withLock { try assertAvailable(key, ownerID: ownerID, in: Array(roots)) }
    }

    /// Explicit roots let an isolated coordination namespace avoid unrelated stores.
    static func assertAvailable(_ key: AgentRuntimeSharedStateKey, ownerID: UUID?, in roots: [URL]) throws {
        for root in roots {
            let store = RuntimeExecutionOwnerStore(root: root)
            for record in try store.records() {
                guard record.ownerID != ownerID, record.resourcesReleased != true,
                      record.providerSharedStateReleased != true, !record.canRecoverPreparation else { continue }
                if record.providerSharedStateKey == key.rawValue {
                    // A live owner waits on the kernel gate. An orphaned or
                    // returned owner must retain its durable quarantine.
                    if record.appProcess.presence == .present {
                        do { let lease = try store.acquire(taskID: record.taskID); withExtendedLifetime(lease) {} }
                        catch RuntimeExecutionOwnerStore.Failure.busy { continue }
                    }
                    throw RuntimeExecutionOwnerStore.Failure.busy
                }
                if record.resourceClaims == nil, record.runtime == "antigravity_cli",
                   !record.canReplace && !record.canBeginNewTurn {
                    throw RuntimeExecutionOwnerStore.Failure.unreadable
                }
            }
        }
    }
}
