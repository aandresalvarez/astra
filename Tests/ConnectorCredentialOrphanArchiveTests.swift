import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Orphaned credential archive retention", .serialized)
struct ConnectorCredentialOrphanArchiveTests {
    @Test("Missing or receipt-free active records never release archived ownership", arguments: ["missing", "receipt", "recreated", "foreign", "stale", "stale_legacy"])
    func lostReceiptBlocksCleanupAndProducers(mode: String) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic archive owner", serviceType: "jira").keychainCleanup
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([candidate]))
        try JSONSerialization.data(withJSONObject: ["version": 1, "storeIdentity": "/synthetic/old.store|1:1", "candidates": encoded])
            .write(to: journal.fileURL)
        let lease = try journal.acquireLease()
        try journal.recoverEditing(lease: lease)
        let recovered = try Data(contentsOf: journal.fileURL)
        var authoritative = recovered
        var expected = [candidate]
        if mode.hasPrefix("stale") {
            let second = Connector(name: "Synthetic later archive owner", serviceType: "jira").keychainCleanup
            expected.append(second)
            var next = try #require(try JSONSerialization.jsonObject(with: recovered) as? [String: Any])
            next["storeIdentity"] = "/synthetic/next.store|1:1"
            next["candidates"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([second]))
            try JSONSerialization.data(withJSONObject: next).write(to: journal.fileURL, options: .atomic)
            try journal.recoverEditing(lease: lease)
            authoritative = try Data(contentsOf: journal.fileURL)
            var stale = try #require(try JSONSerialization.jsonObject(with: recovered) as? [String: Any])
            if mode == "stale_legacy" {
                var receipt = try #require(stale["recovery"] as? [String: Any])
                receipt.removeValue(forKey: "preservedArchives")
                stale["recovery"] = receipt
            }
            try JSONSerialization.data(withJSONObject: stale).write(to: journal.fileURL, options: .atomic)
        }
        else if mode == "missing" { try FileManager.default.removeItem(at: journal.fileURL) }
        else {
            var object = try #require(try JSONSerialization.jsonObject(with: recovered) as? [String: Any])
            object.removeValue(forKey: "recovery")
            if mode == "recreated" { object["candidates"] = encoded }
            if mode == "foreign" { object["storeIdentity"] = "/synthetic/restored.store|1:1" }
            try JSONSerialization.data(withJSONObject: object).write(to: journal.fileURL, options: .atomic)
        }
        let before = try? Data(contentsOf: journal.fileURL)
        #expect(ConnectorCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.context))
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == nil)
        #expect(ConnectorCredentialCleanup.capturedOwnership(modelContext: env.context, extraMirrors: []) == nil)
        let cleanupCandidate = try #require(expected.last)
        var accountCleanupReached = false
        let accountResult = ConnectorCredentialCleanup.run([cleanupCandidate], modelContext: env.context, extraMirrors: [],
            perform: { _, _ in accountCleanupReached = true; return true })
        #expect(!accountResult && !accountCleanupReached)
        let deletion = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: env.disk.root.appendingPathComponent("deleted").path,
            connectors: [cleanupCandidate], skills: [])
        var workspaceCleanupReached = false
        let workspaceResult = WorkspaceDeletionCleanupService.settle(deletion, modelContext: env.context, extraMirrors: [],
            cleanConnectors: { _, _ in workspaceCleanupReached = true; return true })
        #expect(!workspaceResult && !workspaceCleanupReached)
        #expect(throws: (any Error).self) { try journal.record([candidate], lease: lease) }
        #expect(!journal.forget([candidate], lease: lease))
        if mode != "missing" {
            #expect(throws: (any Error).self) { try journal.recoverEditing(lease: lease) }
        }
        #expect((try? Data(contentsOf: journal.fileURL)) == before)
        // Restoring the exact authoritative receipt restores safe collection.
        try authoritative.write(to: journal.fileURL, options: .atomic)
        let retained = try #require(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context))
        #expect(retained.count == expected.count)
        #expect(expected.allSatisfy { retained.contains($0) })
    }

    @Test("A fresh store with no archives can create its first journal")
    func freshStoreRemainsUsable() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [])
        let lease = try journal.acquireLease()
        try journal.record([], lease: lease)
        #expect(try journal.pending().isEmpty)
    }

    @Test("A fully accounted legacy receipt upgrades its inventory without losing holds")
    func legacyReceiptInventoryUpgrade() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic legacy hold", serviceType: "jira").keychainCleanup
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([candidate]))
        try JSONSerialization.data(withJSONObject: ["version": 1, "storeIdentity": "/synthetic/old.store|1:1", "candidates": encoded])
            .write(to: journal.fileURL)
        let lease = try journal.acquireLease()
        try journal.recoverEditing(lease: lease)
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as? [String: Any])
        var receipt = try #require(root["recovery"] as? [String: Any])
        receipt.removeValue(forKey: "preservedArchives")
        root["recovery"] = receipt
        try JSONSerialization.data(withJSONObject: root).write(to: journal.fileURL, options: .atomic)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [candidate])
        try journal.record([], lease: lease)
        let upgraded = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as? [String: Any])
        let recovered = try #require(upgraded["recovery"] as? [String: Any])
        #expect((recovered["preservedArchives"] as? [String])?.count == 1)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [candidate])
    }
}
