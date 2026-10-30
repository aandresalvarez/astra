import CryptoKit
import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Shared credential archive read budget", .serialized)
struct ConnectorCredentialArchiveReadBudgetTests {
    @Test("Reconciliation and ownership share each verified archive exactly once", arguments: [1, 32])
    func admittedLegacyChainReadsOnce(count: Int) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic budget owner", serviceType: "jira").keychainCleanup
        try legacyChain(in: env.context, candidate: candidate, count: count)
        var reads: [(URL, Int)] = []
        let retained = ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context,
            archiveReadObserver: { reads.append(($0, $1)) })
        #expect(retained?.count == count)
        #expect(retained?.allSatisfy { $0 == candidate } == true)
        #expect(reads.count == count)
        #expect(Set(reads.map { $0.0 }).count == count)
        #expect(reads.reduce(0) { $0 + $1.1 } <= 4 * 1_048_576)
    }

    @Test("An ordinary 33-archive scan stops before reading the 33rd archive")
    func depthLimitStopsPhysicalReads() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic depth owner", serviceType: "jira").keychainCleanup
        try legacyChain(in: env.context, candidate: candidate, count: 33)
        var reads: [(URL, Int)] = []
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context,
            archiveReadObserver: { reads.append(($0, $1)) }))
        let original = try Data(contentsOf: journal.fileURL)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context,
            archiveReadObserver: { reads.append(($0, $1)) }) == nil)
        #expect(reads.count == 32)
        // Availability is a bounded probe, not implicit explicit recovery.
        reads.removeAll()
        #expect(journal.canRecoverEditing())
        #expect(reads.count == 32)
        #expect(try Data(contentsOf: journal.fileURL) == original)
        // Explicit recovery enlarges the same session rather than re-reading
        // the first 32 images after its ordinary-sized probe hits the cap.
        reads.removeAll()
        let lease = try journal.acquireLease()
        #expect(try journal.recoverEditing(lease: lease) != nil)
        #expect(reads.count == 33)
        #expect(Set(reads.map { $0.0 }).count == 33)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [candidate])
    }

    @Test("The 4 MiB boundary is shared and never overshot by the next physical read", arguments: [4, 5])
    func byteBoundaryIsShared(count: Int) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic byte owner", serviceType: "jira").keychainCleanup
        try legacyChain(in: env.context, candidate: candidate, count: count, recordBytes: 1_048_576)
        var reads: [(URL, Int)] = []
        let retained = ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context,
            archiveReadObserver: { reads.append(($0, $1)) })
        if count == 4 { #expect(retained?.count == 4) }
        else { #expect(retained == nil) }
        #expect(reads.count == 4)
        #expect(reads.reduce(0) { $0 + $1.1 } == 4 * 1_048_576)
        #expect(Set(reads.map { $0.0 }).count == 4)
    }

    @Test("Explicit recovery shares its larger limit across the probe and both traversals", arguments: [256, 257])
    func explicitRecoveryIsBounded(count: Int) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic explicit limit", serviceType: "jira").keychainCleanup
        try legacyChain(in: env.context, candidate: candidate, count: count)
        var reads: [(URL, Int)] = []
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context,
            archiveReadObserver: { reads.append(($0, $1)) }))
        let before = try Data(contentsOf: journal.fileURL)
        let lease = try journal.acquireLease()
        if count == 256 {
            #expect(try journal.recoverEditing(lease: lease) != nil)
            #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [candidate])
        } else {
            #expect(throws: ConnectorCredentialGenerationJournal.Failure.tooLarge) { try journal.recoverEditing(lease: lease) }
            #expect(try Data(contentsOf: journal.fileURL) == before)
        }
        #expect(reads.count == 256)
        #expect(Set(reads.map { $0.0 }).count == 256)
        #expect(reads.reduce(0) { $0 + $1.1 } <= 32 * 1_048_576)
    }

    @Test("A file larger than the remaining allowance is rejected before reading its bytes")
    func partialRemainingAllowanceDoesNotOvershoot() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic partial allowance", serviceType: "jira").keychainCleanup
        try legacyChain(in: env.context, candidate: candidate, count: 5, recordBytes: 900_000)
        var bytes = 0
        var count = 0
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context,
            archiveReadObserver: { _, size in count += 1; bytes += size }) == nil)
        #expect(count == 4)
        #expect(bytes == 3_600_000)
    }

    @Test("Verified images expire with the operation and corruption is re-read on the next scan")
    func cacheNeverSurvivesScan() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let candidate = Connector(name: "Synthetic fresh scan", serviceType: "jira").keychainCleanup
        let archives = try legacyChain(in: env.context, candidate: candidate, count: 1)
        var reads = 0
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context,
            archiveReadObserver: { _, _ in reads += 1 }) == [candidate])
        #expect(reads == 1)
        try Data("synthetic damaged archive".utf8).write(to: #require(archives.first))
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context,
            archiveReadObserver: { _, _ in reads += 1 }) == nil)
        #expect(reads == 2)
    }

    @discardableResult
    private func legacyChain(in context: ModelContext, candidate: ConnectorKeychainCleanup,
                             count: Int, recordBytes: Int? = nil) throws -> [URL] {
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: context))
        let root = journal.fileURL.deletingLastPathComponent()
        let directory = root.appendingPathComponent("ConnectorCredentialRecovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["ConnectorCredentialCleanup", "WorkspaceDeletionCleanup"] {
            try CredentialRecoveryRetentionBarrier.install(in: root.appendingPathComponent(name))
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([candidate]))
        var recovery: Any?
        var archives: [URL] = []
        for _ in 0..<count {
            var object: [String: Any] = ["version": 2, "storeIdentity": "/synthetic/old.store|1:1", "candidates": encoded]
            object["recovery"] = recovery
            if let recordBytes {
                object["padding"] = ""
                let size = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).count
                object["padding"] = String(repeating: "x", count: recordBytes - size)
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if let recordBytes { #expect(data.count == recordBytes) }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let url = directory.appendingPathComponent(digest + ".json")
            try data.write(to: url, options: .atomic)
            archives.append(url)
            recovery = ["archivedDigest": digest, "recoveredAt": 0, "previousVersion": 2]
        }
        let current: [String: Any] = ["version": 2,
            "storeIdentity": try #require(PersistentStoreIdentity.credentialJournal(for: context)),
            "candidates": [], "recovery": try #require(recovery)]
        try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]).write(to: journal.fileURL, options: .atomic)
        return archives
    }
}
