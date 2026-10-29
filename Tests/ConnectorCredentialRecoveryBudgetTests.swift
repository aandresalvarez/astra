import CryptoKit
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Credential recovery publication budgets", .serialized)
struct ConnectorCredentialRecoveryBudgetTests {
    @Test("Forty store replacements retain every hold and keep collectors usable")
    func repeatedStoreRecoveryCompactsHistory() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let original = Connector(name: "Synthetic retained account", serviceType: "jira",
            baseURL: "https://budget.example.test").keychainCleanup
        let initial = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        do {
            let lease = try initial.acquireLease()
            try initial.record([original], lease: lease)
        }
        var containers: [ModelContainer] = []
        var expected = [original]
        for index in 1...40 {
            let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: ModelConfiguration(url: env.disk.store.deletingLastPathComponent().appendingPathComponent("replacement-\(index).store")))
            containers.append(container)
            container.mainContext.autosaveEnabled = false
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: container.mainContext))
            #expect(journal.fileURL == initial.fileURL)
            #expect(journal.canRecoverEditing())
            do {
                let lease = try journal.acquireLease()
                #expect(try journal.recoverEditing(lease: lease) != nil)
            }
            #expect(!journal.canRecoverEditing())
            let retained = try #require(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: container.mainContext))
            #expect(retained.count == expected.count)
            #expect(expected.allSatisfy { retained.contains($0) })
            try assertCollectorsRetain(original, context: container.mainContext, root: env.disk.root)
            // The same logical account can retire distinct generations. A
            // compactor must keep all facts, rather than deduplicating by ID.
            if index < 40 {
                var next = original
                next.credentialNamespaceID = UUID()
                let lease = try journal.acquireLease()
                try journal.record([next], lease: lease)
                expected.append(next)
            }
        }
        withExtendedLifetime(containers) {}
    }

    @Test("Explicit recovery repairs a matching legacy chain beyond collection's budget",
          arguments: ["depth", "bytes"], [false, true])
    func repairsPreviouslyPublishedHistory(limit: String, matches: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = Connector(name: limit == "bytes" ? String(repeating: "s", count: 800_000) : "Synthetic hold",
            serviceType: "jira", baseURL: "https://budget.example.test")
        let candidate = account.keychainCleanup
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let archives = try legacyChain(journal, context: env.context, candidate: candidate,
            count: limit == "depth" ? 33 : 6, matches: matches)
        let source = try Data(contentsOf: journal.fileURL)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == nil)
        #expect(journal.canRecoverEditing())
        do {
            let lease = try journal.acquireLease()
            let receipt = try #require(try journal.recoverEditing(lease: lease))
            let original = journal.fileURL.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialRecovery")
                .appendingPathComponent(try #require(receipt.sourceDigest) + ".json")
            #expect(try Data(contentsOf: original) == source)
        }
        #expect(!journal.canRecoverEditing())
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [candidate])
        for (url, bytes) in archives { #expect(try Data(contentsOf: url) == bytes) }
        try assertCollectorsRetain(candidate, context: env.context, root: env.disk.root)
    }

    @Test("An overfull distinct-hold snapshot is rejected before publication")
    func cannotPublishOversizedSnapshot() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let candidate = Connector(name: String(repeating: "s", count: 800_000), serviceType: "jira").keychainCleanup
        _ = try legacyChain(journal, context: env.context, candidate: candidate, count: 1, matches: false)
        var current = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as? [String: Any])
        let second = Connector(name: String(repeating: "t", count: 800_000), serviceType: "jira").keychainCleanup
        current["candidates"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([second]))
        let original = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
        try original.write(to: journal.fileURL, options: .atomic)
        let lease = try journal.acquireLease()
        #expect(throws: ConnectorCredentialGenerationJournal.Failure.tooLarge) { try journal.recoverEditing(lease: lease) }
        #expect(try Data(contentsOf: journal.fileURL) == original)
        #expect(journal.canRecoverEditing())
    }

    private func assertCollectorsRetain(_ candidate: ConnectorKeychainCleanup, context: ModelContext, root: URL) throws {
        let namespaces = Set(try #require(KeychainSecretStore.ownedConnectorEntityIDs(for: candidate.secretFacts)))
        let ownership = try #require(ConnectorCredentialCleanup.capturedOwnership(modelContext: context, extraMirrors: []))
        #expect(namespaces.isSubset(of: ownership.namespaces))
        var accountReached = false
        let accountSettled = ConnectorCredentialCleanup.run([candidate], modelContext: context, extraMirrors: [], perform: { _, owners in
            accountReached = true
            #expect(namespaces.isSubset(of: owners.namespaces))
            return true
        })
        #expect(accountSettled)
        #expect(accountReached)
        var workspaceReached = false
        let deletion = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: root.appendingPathComponent("removed").path,
            connectors: [candidate], skills: [])
        let workspaceSettled = WorkspaceDeletionCleanupService.settle(deletion, modelContext: context, extraMirrors: [], cleanConnectors: { _, owners in
            workspaceReached = true
            #expect(namespaces.isSubset(of: owners.namespaces))
            return true
        })
        #expect(workspaceSettled)
        #expect(workspaceReached)
    }

    /// Format emitted before compaction existed. All bytes are synthetic;
    /// repeated large candidates exercise the actual aggregate-byte limit.
    private func legacyChain(_ journal: ConnectorCredentialGenerationJournal, context: ModelContext,
                             candidate: ConnectorKeychainCleanup, count: Int, matches: Bool) throws -> [(URL, Data)] {
        let directory = journal.fileURL.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialRecovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([candidate]))
        var recovery: Any?
        var archives: [(URL, Data)] = []
        for _ in 0..<count {
            var object: [String: Any] = ["version": 2, "storeIdentity": "/synthetic/previous.store|1:1", "candidates": encoded]
            object["recovery"] = recovery
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let url = directory.appendingPathComponent(digest + ".json")
            try data.write(to: url, options: .atomic)
            archives.append((url, data))
            recovery = ["archivedDigest": digest, "recoveredAt": 0, "previousVersion": 2]
        }
        let identity = matches ? try #require(PersistentStoreIdentity.credentialJournal(for: context)) : "/synthetic/other.store|1:1"
        let current: [String: Any] = ["version": 2, "storeIdentity": identity, "candidates": [], "recovery": try #require(recovery)]
        try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]).write(to: journal.fileURL, options: .atomic)
        return archives
    }
}
