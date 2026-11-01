import Foundation
import ASTRACore

/// Registered store roots are a cache of locations, not release authority.
/// Every acquisition reads durable receipts again, including after restart.
enum RuntimeProviderResourceRegistry {
    /// A refusal to launch, not evidence that the previous execution stopped.
    /// Keep the identifiers for callers without making display prose authority.
    struct Block: LocalizedError, Equatable, Sendable {
        static let stopReason = "provider_shared_state_blocked"
        let key: AgentRuntimeSharedStateKey
        let taskID: UUID
        let ownerID: UUID
        let missingClaims: Bool
        let legacyIdentity: Bool

        init(key: AgentRuntimeSharedStateKey, record: RuntimeExecutionOwnerRecord, missingClaims: Bool = false) {
            self.key = key
            taskID = record.taskID
            ownerID = record.ownerID
            self.missingClaims = missingClaims
            legacyIdentity = key.filePath != nil && ([record.providerSharedStateKey].compactMap { $0 }
                + (record.retainedProviderSharedStateKeys ?? [])).contains { $0 != key.rawValue && key.conflicts(withRecorded: $0) }
        }

        var message: String {
            let parts = key.rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let provider = parts.first.flatMap { AgentRuntimeID(rawValue: String($0)) }?.displayName ?? "The provider"
            let resource = key.filePath ?? (parts.count == 2 ? String(parts[1]) : key.rawValue)
            let reason = missingClaims
                ? "Its ownership records are incomplete, so ASTRA cannot verify that this shared configuration is available."
                : legacyIdentity
                ? "An older reservation did not capture the configuration's physical identity. ASTRA must preserve it until the earlier execution and tools are confirmed stopped, even if this profile uses a different path."
                : "Its shared configuration remains reserved because ASTRA cannot verify that its earlier execution and tools stopped."
            return "\(provider) did not start. Task \(taskID.uuidString) blocks this launch. \(reason) Resource: \(resource). Review the owning task; this task stays paused and will not restart automatically."
        }

        var errorDescription: String? { message }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var roots: Set<URL> = []
    static func register(_ root: URL) { _ = lock.withLock { roots.insert(root) } }
    /// Retire only after a store's producers have joined, before deleting it.
    /// Joining the scan lock prevents readers from traversing partially removed files.
    static func unregister(_ root: URL) { _ = lock.withLock { roots.remove(root) } }
    static func assertAvailable(_ key: AgentRuntimeSharedStateKey, ownerID: UUID?, reference: RuntimeProviderOwnershipReference? = nil, reading: Bool = false) throws {
        try lock.withLock { try assertAvailable(key, ownerID: ownerID, in: Array(roots), reference: reference, reading: reading) }
    }

    /// Explicit roots let an isolated coordination namespace avoid unrelated stores.
    static func assertAvailable(_ key: AgentRuntimeSharedStateKey, ownerID: UUID?, in roots: [URL], reference: RuntimeProviderOwnershipReference? = nil, reading: Bool = false) throws {
        for root in roots {
            let store = RuntimeExecutionOwnerStore(root: root)
            for record in try store.records() {
                let sameOwner = reference?.ownerID == record.ownerID && reference?.taskID == record.taskID
                    && reference?.journalRoot == root.path && ownerID == record.ownerID
                guard !sameOwner, record.resourcesReleased != true,
                      record.providerSharedStateReleased != true, !record.canRecoverPreparation else { continue }
                if conflicts(key, record: record, checkingHistoryIn: reading ? store : nil) {
                    // A live owner waits on the kernel gate. An orphaned or
                    // returned owner must retain its durable quarantine.
                    if record.appProcess.presence == .present, record.providerSharedStateKey == key.rawValue,
                       record.retainedProviderSharedStateKeys?.contains(where: key.conflicts) != true {
                        do { let lease = try store.acquire(taskID: record.taskID); withExtendedLifetime(lease) {} }
                        catch RuntimeExecutionOwnerStore.Failure.busy { continue }
                    }
                    throw Block(key: key, record: record)
                }
                if record.resourceClaims == nil, record.runtime == "antigravity_cli",
                   !record.canReplace && !record.canBeginNewTurn {
                    throw Block(key: key, record: record, missingClaims: true)
                }
            }
        }
    }

    /// Readers may pass a stopped writer even if it crashed before recording release.
    /// Claims inherited from earlier writers still need their own proof.
    static func conflicts(_ key: AgentRuntimeSharedStateKey, record: RuntimeExecutionOwnerRecord,
                          checkingHistoryIn store: RuntimeExecutionOwnerStore? = nil, requireExactWriter: Bool = false) -> Bool {
        if let current = record.providerSharedStateKey, key.conflicts(withRecorded: current),
           store == nil || !record.canReplace { return true }
        var inherited = Set((record.retainedProviderSharedStateKeys ?? []).filter(key.conflicts))
        if requireExactWriter && record.providerSharedStateKey != key.rawValue { inherited.insert(key.rawValue) }
        guard !inherited.isEmpty else { return false }
        if record.providerSharedStateReleased == false && record.providerSharedStateKey == nil { return true }
        guard let store, let history = try? store.retainedExecutions(of: record) else { return true }
        var proven = Set<String>()
        for prior in history.reversed() {
            let carried = Set(prior.retainedProviderSharedStateKeys ?? []).intersection(inherited)
            guard carried.isSubset(of: proven) else { return true }
            if prior.providerSharedStateReleased == false && prior.providerSharedStateKey == nil { return true }
            guard let written = prior.providerSharedStateKey, inherited.contains(written) else { continue }
            guard prior.providerSharedStateReleased == true || prior.canReplace || prior.canRecoverPreparation else { return true }
            proven.insert(written)
        }
        return !inherited.isSubset(of: proven)
    }
}
