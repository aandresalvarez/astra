import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

extension RuntimeNativeSessionOwnershipTests {
    @Test("Orphaned audits read each protected receipt once per scan without dropping audit identities")
    func orphanedHistoryReadsAreBounded() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = h.makeTask(runtime: .copilotCLI, goal: "Preserve uncertain history", model: "gpt-5")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        try owner.prepareLaunch(sessionID: "protected-0")
        owner.stopped(proof: nil, turns: 1, tokens: 6, seconds: 1)
        let currentURL = try #require(owner.receiptURL)
        owner.finish()
        let store = RuntimeExecutionOwner.store(in: h.context)
        var current = owner.record
        current.resourceClaims?.removeAll { $0.resourceKind == .nativeSession }
        var sessions: [String] = []
        for index in 0...32 {
            if index > 0 {
                try store.retain(current)
                let prior = current.executionID
                current.executionID = UUID()
                current.retainedExecutionHead = prior
                current.sessionID = "protected-\(index)"
            }
            // Multiple snapshots can name different sessions within the same
            // execution. None of those audit roots may be deduplicated away.
            for identity in [current.sessionID!, "audit-\(index)-a", "audit-\(index)-b"] {
                var audit = current
                audit.sessionID = identity
                audit.resourcesReleased = true // an audit cannot prove release
                h.context.insert(TaskEvent(task: source, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                    payload: TaskEvent.payloadString(audit)))
                sessions.append(identity)
            }
        }
        try h.context.save()
        try FileManager.default.removeItem(at: currentURL)
        var lastRead: URL?
        for _ in 0..<2 {
            var reads: [URL: Int] = [:]
            let claims = try RuntimeResourceOwnership.claims(in: store, context: h.context, readRetained: { url in
                reads[url, default: 0] += 1
                lastRead = url
                return try RuntimeExecutionOwnerStore.read(url)
            })
            #expect(reads.count == 32)
            #expect(reads.values.reduce(0, +) == 32)
            for identity in sessions {
                let requested = try #require(RuntimeNativeSessionOwnership.claim(runtime: "copilot_cli", sessionID: identity, taskID: UUID()))
                #expect(!TaskExecutionResourceBroker.canAcquire([requested], active: claims))
            }
            let independent = try #require(RuntimeNativeSessionOwnership.claim(runtime: "copilot_cli", sessionID: "independent", taskID: UUID()))
            #expect(TaskExecutionResourceBroker.canAcquire([independent], active: claims))
        }
        // A later scan must not retain the cache or use audit data to fill a
        // missing protected receipt.
        try FileManager.default.removeItem(at: try #require(lastRead))
        #expect(throws: (any Error).self) { try RuntimeResourceOwnership.claims(in: store, context: h.context) }

        // Attribution and cycle checks also apply when a caller reuses a
        // protected read. No audit snapshot is an entry in this cache.
        var protected = current
        protected.retainedExecutionHead = nil
        protected.executionID = UUID()
        try store.retain(protected)
        var root = current
        root.retainedExecutionHead = protected.executionID
        var cache: [URL: RuntimeExecutionOwnerRecord] = [:]
        func read(_ url: URL) throws -> RuntimeExecutionOwnerRecord? {
            if let record = cache[url] { return record }
            let record = try RuntimeExecutionOwnerStore.read(url)
            cache[url] = record
            return record
        }
        #expect(try store.retainedExecutions(of: root, read: read) == [protected])
        let other = h.makeTask(runtime: .copilotCLI, goal: "Different owner", model: "gpt-5")
        var wrongOwner = root
        wrongOwner.taskOwnerID = other.persistentModelID
        #expect(throws: (any Error).self) { try store.retainedExecutions(of: wrongOwner, read: read) }
        var cycle = root
        cycle.executionID = protected.executionID
        #expect(throws: (any Error).self) { try store.retainedExecutions(of: cycle, read: read) }
    }
}
