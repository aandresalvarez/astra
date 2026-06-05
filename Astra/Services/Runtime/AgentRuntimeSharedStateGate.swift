import Foundation
import ASTRACore

struct AgentRuntimeSharedStateKey: Hashable, Sendable {
    let rawValue: String

    init(runtime: AgentRuntimeID, identifier: String) {
        self.rawValue = "\(runtime.rawValue):\(identifier)"
    }
}

actor AgentRuntimeSharedStateGate {
    static let shared = AgentRuntimeSharedStateGate()

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var heldKeys: Set<AgentRuntimeSharedStateKey> = []
    private var waiters: [AgentRuntimeSharedStateKey: [Waiter]] = [:]

    func acquire(_ key: AgentRuntimeSharedStateKey) async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        if heldKeys.insert(key).inserted {
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await enqueueWaiter(id: waiterID, key: key)
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, key: key) }
        }

        guard acquired else {
            throw CancellationError()
        }

        if Task.isCancelled {
            release(key)
            throw CancellationError()
        }
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

    func release(_ key: AgentRuntimeSharedStateKey) {
        guard var queued = waiters[key], !queued.isEmpty else {
            heldKeys.remove(key)
            return
        }

        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.continuation.resume(returning: true)
    }
}
