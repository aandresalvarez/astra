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

    private var heldKeys: Set<AgentRuntimeSharedStateKey> = []
    private var waiters: [AgentRuntimeSharedStateKey: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: AgentRuntimeSharedStateKey) async {
        if heldKeys.insert(key).inserted {
            return
        }

        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: AgentRuntimeSharedStateKey) {
        guard var queued = waiters[key], !queued.isEmpty else {
            heldKeys.remove(key)
            return
        }

        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.resume()
    }
}
