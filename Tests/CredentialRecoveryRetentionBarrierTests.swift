import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Credential recovery retention fence", .serialized)
struct CredentialRecoveryRetentionBarrierTests {
    @Test("An existing matching v2 receipt can explicitly restore its missing fence")
    func upgradesExistingReceipt() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try Data("{\"version\":1,\"storeIdentity\":\"/synthetic/other.store|1:1\",\"candidates\":[]}".utf8).write(to: journal.fileURL)
        let lease = try journal.acquireLease()
        _ = try journal.recoverEditing(lease: lease)
        let original = try Data(contentsOf: journal.fileURL)
        let outbox = WorkspaceDeletionCleanupStore(for: env.context)
        let fence = outbox.directory.appendingPathComponent(CredentialRecoveryRetentionBarrier.filename)
        try FileManager.default.removeItem(at: fence)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == nil)
        #expect(journal.canRecoverEditing())
        #expect(try journal.recoverEditing(lease: lease) == nil)
        #expect(!journal.canRecoverEditing())
        #expect(try Data(contentsOf: journal.fileURL) == original)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [])
    }

    @Test("A failed journal publication leaves a durable fence and retries safely")
    func publicationFailureKeepsFence() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let original = Data("{\"version\":1,\"storeIdentity\":\"/synthetic/other.store|1:1\",\"candidates\":[]}".utf8)
        try original.write(to: journal.fileURL)
        let outbox = WorkspaceDeletionCleanupStore(for: env.context)
        let fence = outbox.directory.appendingPathComponent(CredentialRecoveryRetentionBarrier.filename)
        let lease = try journal.acquireLease()
        #expect(throws: CocoaError.self) {
            try journal.recoverEditing(lease: lease, publish: { _, _ in
                try CredentialRecoveryRetentionBarrier.validate(at: fence)
                throw CocoaError(.fileWriteNoPermission)
            })
        }
        #expect(try Data(contentsOf: journal.fileURL) == original)
        let bytes = try Data(contentsOf: fence)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: bytes) }
        #expect(outbox.pendingConnectors() == [])
        #expect(outbox.pendingMirrorPaths() == [])
        #expect(outbox.pendingMirrorIdentities() == [])
        #expect(outbox.pending().isEmpty)
        let accountOutbox = try #require(ConnectorCredentialCleanupStore(for: env.context))
        #expect(accountOutbox.pending()?.complete == true)
        let accountFence = accountOutbox.directory.appendingPathComponent(CredentialRecoveryRetentionBarrier.filename)
        #expect(try Data(contentsOf: accountFence) == bytes)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ConnectorKeychainCleanup.self, from: bytes) }
        #expect(try journal.recoverEditing(lease: lease) != nil)
        #expect(try Data(contentsOf: fence) == bytes)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [])
    }

    @Test("A damaged or unsupported fence blocks publication and its ownership scan",
          arguments: ["damaged", "future", "symlink", "directory"], ["accounts", "workspaces"])
    func unverifiableFenceRemainsUntouched(kind: String, scope: String) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let original = Data("{\"version\":1,\"storeIdentity\":\"/synthetic/other.store|1:1\",\"candidates\":[]}".utf8)
        try original.write(to: journal.fileURL)
        let outbox = WorkspaceDeletionCleanupStore(for: env.context)
        let accountOutbox = try #require(ConnectorCredentialCleanupStore(for: env.context))
        let directory = scope == "accounts" ? accountOutbox.directory : outbox.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fence = directory.appendingPathComponent(CredentialRecoveryRetentionBarrier.filename)
        let bytes = Data(kind == "future" ? "{\"kind\":\"account_credential_recovery_retention\",\"version\":3}".utf8 : "broken".utf8)
        let target = env.disk.root.appendingPathComponent("untouched-target")
        if kind == "directory" { try FileManager.default.createDirectory(at: fence, withIntermediateDirectories: true) }
        else if kind == "symlink" {
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: fence, withDestinationURL: target)
        } else { try bytes.write(to: fence) }
        let lease = try journal.acquireLease()
        #expect(throws: (any Error).self) { try journal.recoverEditing(lease: lease) }
        #expect(try Data(contentsOf: journal.fileURL) == original)
        if scope == "workspaces" {
            #expect(outbox.pendingConnectors() == nil)
            #expect(outbox.pendingMirrorPaths() == nil)
            #expect(outbox.pendingMirrorIdentities() == nil)
        } else { #expect(accountOutbox.pending()?.complete == false) }
        #expect(journal.canRecoverEditing())
        if kind == "symlink" { #expect(try Data(contentsOf: target) == bytes) }
    }
}
