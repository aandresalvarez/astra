import Foundation
import ASTRACore

struct AgentRuntimeSharedStateKey: Hashable, Sendable {
    let rawValue: String

    init(runtime: AgentRuntimeID, identifier: String) {
        self.rawValue = "\(runtime.rawValue):\(identifier)"
    }
}

/// One holder's turn on a shared-state key. Releasing it is idempotent: a
/// stale lease (already released, or reclaimed after a wedged cancel) never
/// frees the key for whoever holds it now.
struct AgentRuntimeSharedStateLease: Hashable, Sendable {
    let key: AgentRuntimeSharedStateKey
    let id: UUID
}

actor AgentRuntimeSharedStateGate {
    static let shared = AgentRuntimeSharedStateGate()

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
        var timer: Task<Void, Never>?
    }

    private let processLockRoot: URL?
    private let registeredStoreRoots: [URL]?
    init(processLockRoot: URL? = nil, registeredStoreRoots: [URL]? = nil) {
        self.processLockRoot = processLockRoot
        self.registeredStoreRoots = registeredStoreRoots
    }

    private func checkAvailability(_ key: AgentRuntimeSharedStateKey, reference: RuntimeProviderOwnershipReference?) throws {
        if let registeredStoreRoots {
            try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: reference?.ownerID, in: registeredStoreRoots, reference: reference)
        } else {
            try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: reference?.ownerID, reference: reference)
        }
    }

    private var processLocks: [UUID: ProviderSharedStateProcessLock] = [:]
    private var holders: [AgentRuntimeSharedStateKey: UUID] = [:]
    private var waiters: [AgentRuntimeSharedStateKey: [Waiter]] = [:]

    @discardableResult
    func acquire(_ key: AgentRuntimeSharedStateKey, owner: RuntimeExecutionOwner? = nil, timeoutSeconds: TimeInterval = 120) async throws -> AgentRuntimeSharedStateLease {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 120))
        let ownerReference = await owner?.providerOwnershipReference
        if Task.isCancelled {
            throw CancellationError()
        }

        try checkAvailability(key, reference: ownerReference)
        let leaseID = UUID()
        if holders[key] == nil {
            holders[key] = leaseID
            return try await finishAcquisition(.init(key: key, id: leaseID), owner: owner, reference: ownerReference, deadline: deadline)
        }

        let acquired = await withTaskCancellationHandler {
            await enqueueWaiter(id: leaseID, key: key, deadline: deadline)
        } onCancel: {
            Task { await self.cancelWaiter(id: leaseID, key: key) }
        }

        let lease = AgentRuntimeSharedStateLease(key: key, id: leaseID)
        guard acquired else {
            if Task.isCancelled { throw CancellationError() }
            throw RuntimeProviderStateWaitTimeout()
        }

        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return try await finishAcquisition(lease, owner: owner, reference: ownerReference, deadline: deadline)
    }

    private func finishAcquisition(_ lease: AgentRuntimeSharedStateLease, owner: RuntimeExecutionOwner?, reference: RuntimeProviderOwnershipReference?, deadline: ContinuousClock.Instant) async throws -> AgentRuntimeSharedStateLease {
        do {
            let processLock = try await ProviderSharedStateProcessLock.acquire(lease.key, root: processLockRoot, deadline: deadline)
            try Task.checkCancellation()
            try checkAvailability(lease.key, reference: reference)
            guard ContinuousClock.now < deadline else { throw RuntimeProviderStateWaitTimeout() }
            try await MainActor.run {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw RuntimeProviderStateWaitTimeout() }
                try processLock.handoff(lease.key, reference: reference) {
                    try owner?.bindProviderSharedState(lease.key)
                }
            }
            guard ContinuousClock.now < deadline else { throw RuntimeProviderStateWaitTimeout() }
            guard holders[lease.key] == lease.id else { throw CancellationError() }
            processLocks[lease.id] = processLock
            return lease
        } catch { release(lease); throw error }
    }

    private func enqueueWaiter(id: UUID, key: AgentRuntimeSharedStateKey, deadline: ContinuousClock.Instant) async -> Bool {
        if Task.isCancelled {
            return false
        }

        return await withCheckedContinuation { continuation in
            let timer = Task {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                self.cancelWaiter(id: id, key: key)
            }
            waiters[key, default: []].append(Waiter(id: id, continuation: continuation, timer: timer))
        }
    }

    private func cancelWaiter(id: UUID, key: AgentRuntimeSharedStateKey) {
        guard var queued = waiters[key],
              let index = queued.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = queued.remove(at: index)
        waiter.timer?.cancel()
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }

    /// Hands the key to the next waiter, or frees it. Returns false (and does
    /// nothing) when `lease` no longer holds the key.
    @discardableResult
    func release(_ lease: AgentRuntimeSharedStateLease) -> Bool {
        guard holders[lease.key] == lease.id else { return false }
        processLocks.removeValue(forKey: lease.id)
        guard var queued = waiters[lease.key], !queued.isEmpty else {
            holders.removeValue(forKey: lease.key)
            return true
        }

        let next = queued.removeFirst()
        next.timer?.cancel()
        waiters[lease.key] = queued.isEmpty ? nil : queued
        holders[lease.key] = next.id
        next.continuation.resume(returning: true)
        return true
    }

    func isHeld(_ lease: AgentRuntimeSharedStateLease) -> Bool {
        holders[lease.key] == lease.id
    }

    #if DEBUG
    func queuedWaiterCount(for key: AgentRuntimeSharedStateKey) -> Int { waiters[key]?.count ?? 0 }
    #endif
}
