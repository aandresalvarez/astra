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
    }

    private var holders: [AgentRuntimeSharedStateKey: UUID] = [:]
    private var waiters: [AgentRuntimeSharedStateKey: [Waiter]] = [:]

    @discardableResult
    func acquire(_ key: AgentRuntimeSharedStateKey) async throws -> AgentRuntimeSharedStateLease {
        if Task.isCancelled {
            throw CancellationError()
        }

        let leaseID = UUID()
        if holders[key] == nil {
            holders[key] = leaseID
            return AgentRuntimeSharedStateLease(key: key, id: leaseID)
        }

        let acquired = await withTaskCancellationHandler {
            await enqueueWaiter(id: leaseID, key: key)
        } onCancel: {
            Task { await self.cancelWaiter(id: leaseID, key: key) }
        }

        let lease = AgentRuntimeSharedStateLease(key: key, id: leaseID)
        guard acquired else {
            throw CancellationError()
        }

        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func enqueueWaiter(id: UUID, key: AgentRuntimeSharedStateKey) async -> Bool {
        if Task.isCancelled {
            return false
        }

        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID, key: AgentRuntimeSharedStateKey) {
        guard var queued = waiters[key],
              let index = queued.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }

    /// Hands the key to the next waiter, or frees it. Returns false (and does
    /// nothing) when `lease` no longer holds the key.
    @discardableResult
    func release(_ lease: AgentRuntimeSharedStateLease) -> Bool {
        guard holders[lease.key] == lease.id else { return false }
        guard var queued = waiters[lease.key], !queued.isEmpty else {
            holders.removeValue(forKey: lease.key)
            return true
        }

        let next = queued.removeFirst()
        waiters[lease.key] = queued.isEmpty ? nil : queued
        holders[lease.key] = next.id
        next.continuation.resume(returning: true)
        return true
    }

    func isHeld(_ lease: AgentRuntimeSharedStateLease) -> Bool {
        holders[lease.key] == lease.id
    }
}
