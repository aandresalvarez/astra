import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Who holds what is read at every send, launch and turn end, on the main
/// actor, and every read fetches every ownership event in the store. It used
/// to decode each of them again: about 1,550 events and 3 MB of JSON in a
/// store with a year of history, four times per send. These pin that each
/// event is decoded once, and again only when its text changes.
@Suite("An ownership read decodes each ownership event once", .serialized)
@MainActor
struct RuntimeOwnershipReadCostTests {
    private static let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)

    /// Ownership events as the release rule writes them, for tasks that hold nothing.
    private func audits(_ h: HeadlessChatHarness, count: Int) throws -> [TaskEvent] {
        let events = (0..<count).map { index -> TaskEvent in
            let task = h.makeTask(runtime: .claudeCode, goal: "Audit \(index)", model: "test")
            var record = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: UUID(), executionID: UUID(), runID: nil,
                appProcess: Self.dead, providerProcess: nil, runtime: task.resolvedRuntimeID.rawValue, sessionID: nil,
                state: .finished, limits: .init(tokenCeiling: 1_000, turnsRemaining: 4, secondsRemaining: 60, tokensSpent: 0, costSpent: 0),
                stopProof: nil, updatedAt: Date())
            record.taskOwnerID = task.persistentModelID
            record.resourceClaims = []
            record.resourcesReleased = true
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(record, fallback: "{}"))
            h.context.insert(event)
            return event
        }
        try h.context.save()
        return events
    }

    @Test("Each ownership event is decoded once, and again only when its text changes")
    func auditsDecodeOnce() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let events = try audits(h, count: 4)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let decodes = RuntimeOwnershipAuditDecodes()

        _ = try RuntimeResourceOwnership.claims(in: store, context: h.context, audits: decodes)
        #expect(decodes.decodeCount == 4)
        _ = try RuntimeResourceOwnership.claims(in: store, context: h.context, audits: decodes)
        #expect(decodes.decodeCount == 4)

        // A new event is decoded; the others are not. One that does not
        // decode is skipped, as before, and not decoded again.
        _ = try audits(h, count: 1)
        let unreadable = TaskEvent(task: try #require(events[1].task), eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "not a receipt")
        h.context.insert(unreadable); try h.context.save()
        _ = try RuntimeResourceOwnership.claims(in: store, context: h.context, audits: decodes)
        #expect(decodes.decodeCount == 6)
        _ = try RuntimeResourceOwnership.claims(in: store, context: h.context, audits: decodes)
        #expect(decodes.decodeCount == 6)

        // A kept answer is only ever for the text it was decoded from.
        let changed = events[0]
        var record = try #require(try? JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: Data(changed.payload.utf8)))
        record.resourcesReleased = false
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(
            for: nil, task: try #require(changed.task), runMode: "previous", sandboxEnforcement: .off)
        changed.payload = TaskEvent.payloadString(record, fallback: "{}")
        try h.context.save()
        let held = try RuntimeResourceOwnership.claims(in: store, context: h.context, audits: decodes)
        #expect(decodes.decodeCount == 7)
        #expect(Set(held) == Set(record.resourceClaims ?? []) && !held.isEmpty)
        // And the answer is the one a fresh decode gives.
        #expect(Set(try RuntimeResourceOwnership.claims(in: store, context: h.context)) == Set(held))
    }

    @Test("The queue's reads keep decoded events; a read that is not given a cache keeps nothing")
    func queueReadsKeepDecodes() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        _ = try audits(h, count: 3)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let shared = RuntimeOwnershipAuditDecodes.shared
        let queue = TaskQueue(poolSize: 0)

        // Synchronous on the main actor, so no other read of the shared cache runs in between.
        let start = shared.decodeCount
        queue.refreshResourceOwnership(in: h.context)
        let first = shared.decodeCount - start
        queue.refreshResourceOwnership(in: h.context)
        let second = shared.decodeCount - start - first
        _ = try RuntimeResourceOwnership.claims(in: store, context: h.context)
        let uncached = shared.decodeCount - start - first - second
        #expect(!queue.resourceOwnershipReadFailed)
        #expect(first == 3 && second == 0 && uncached == 0)
    }
}
