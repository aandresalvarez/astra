import CryptoKit
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Downgrade regression with two synthetic stores and a private test vault.
@MainActor
@Suite("Credential recovery downgrade retention", .serialized)
struct ConnectorCredentialRecoveryDowngradeTests {
    @Test("The schema-21 collector honors the v2 retention fence before deleting a shared alias", arguments: [false, true])
    func legacyCollectorHonorsRetentionFence(tracked: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let storeA = try PluginAddCommitTests.Fixture(installed: false)
            let storeB = try PluginAddCommitTests.Fixture(installed: false)
            defer { storeA.disk.removeFiles(); storeB.disk.removeFiles() }
            let original = Connector(name: "Synthetic recovery owner", serviceType: "jira", baseURL: "https://review571.example.test", authMethod: "basic")
            original.isGlobal = true
            original.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
            original.credentialValues = ["", ""]
            storeA.context.insert(original)
            try storeA.context.save()
            let oldOwner = original.keychainCleanup
            let stableSlot = try #require(KeychainSecretStore.stableConnectorEntityID(for: original))
            let oldNamespaces = try #require(KeychainSecretStore.ownedConnectorEntityIDs(for: oldOwner.secretFacts))
            try #require(oldNamespaces.contains(stableSlot))
            try #require(AstraSecureKeychainStore.save(service: stableSlot, account: "JIRA_API_TOKEN", value: "synthetic-retained-token", label: nil))

            // B is a recovered replacement with the same logical account.
            let active = Connector(name: original.name, serviceType: original.serviceType, baseURL: original.baseURL, authMethod: original.authMethod)
            active.id = original.id
            active.isGlobal = true
            active.credentialKeys = original.credentialKeys
            active.credentialValues = ["", ""]
            storeB.context.insert(active)
            // A previously deleted B account shared the legacy endpoint alias.
            let deleted = Connector(name: "Synthetic old deletion", serviceType: "jira", baseURL: original.baseURL, authMethod: "basic")
            deleted.isGlobal = true
            storeB.context.insert(deleted)
            try storeB.context.save()
            let cleanup = deleted.keychainCleanup
            let cleanupNamespaces = try #require(KeychainSecretStore.ownedConnectorEntityIDs(for: cleanup.secretFacts))
            try #require(cleanupNamespaces.contains(stableSlot))
            let outbox = try #require(ConnectorCredentialCleanupStore(for: storeB.context))
            _ = try outbox.record([cleanup], storeIdentity: PersistentStoreIdentity.current(for: storeB.context))
            storeB.context.delete(deleted)
            try storeB.context.save()
            outbox.markCommitted([cleanup])
            try #require(outbox.pending()?.records.map(\.committed) == [true])
            try #require(outbox.pending()?.records.map(\.cleanup) == [cleanup])

            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: storeB.context))
            let candidates = try JSONSerialization.jsonObject(with: JSONEncoder().encode([oldOwner]))
            let data = try JSONSerialization.data(withJSONObject: ["version": 1,
                "storeIdentity": try #require(PersistentStoreIdentity.current(for: storeA.context)), "candidates": candidates])
            try data.write(to: journal.fileURL, options: .atomic)
            try ConnectorCredentialEditor.recoverJournal(on: active, modelContext: storeB.context)
            let failure = try ConnectorCredentialEditor.save(["JIRA_EMAIL": "new@example.test", "JIRA_API_TOKEN": "synthetic-current-token"],
                on: active, modelContext: storeB.context, rewriteMirror: { _ in true })
            #expect(failure == nil)
            #expect(active.credentialNamespaceID != nil)
            #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: storeB.context) == [oldOwner])
            let supportedByBase = PersistentStoreCompatibilityService.assess(storeURL: storeB.disk.store, latestSupportedSchemaVersion: 21)
            #expect(supportedByBase == .compatible(storeSchemaVersion: 21))

            // New collector preserves the shared alias. Do not settle the
            // outbox yet: closing before deferred startup is a supported cut.
            #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: storeB.context, extraMirrors: []))
            #expect(AstraSecureKeychainStore.read(service: stableSlot, account: "JIRA_API_TOKEN") == .value("synthetic-retained-token"))
            #expect(outbox.pending()?.records.count == 1)
            let priorTrust = WorkspaceRecoveryTrust.state
            WorkspaceRecoveryTrust.set(tracked ? .trusted : .notTracked)
            defer { WorkspaceRecoveryTrust.set(priorTrust) }
            let guarded = try #require(ConnectorCredentialCleanup.capturedOwnership(modelContext: storeB.context, extraMirrors: []))
            #expect(guarded.namespaces.contains(stableSlot))
            // The older decoder cannot establish ownership with the durable
            // fence present, even when a legacy deletion is already committed.
            if tracked { #expect(LegacyV21ConnectorCredentialCleanup.capturedOwnership(modelContext: storeB.context, extraMirrors: []) == nil) }
            #expect(LegacyV21ConnectorCredentialCleanupStore(directory: outbox.directory).pending()?.complete == false)
            #expect(LegacyV21ConnectorCredentialCleanup.resumePending(modelContext: storeB.context, store: LegacyV21ConnectorCredentialCleanupStore(directory: outbox.directory), extraMirrors: []) == 0)
            #expect(outbox.pending()?.records.count == 1)
            #expect(original.currentCredentialValue(forKey: "JIRA_API_TOKEN") == "synthetic-retained-token")
            // Current collectors recognize the fence and settle ordinary and
            // workspace deletion debt while sparing all archived namespaces.
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: storeB.context, store: outbox, extraMirrors: []) == 1)
            let deletion = WorkspaceDeletionCleanupRecord(workspaceID: UUID(),
                primaryPath: storeB.disk.root.appendingPathComponent("removed").path, connectors: [cleanup], skills: [])
            #expect(WorkspaceDeletionCleanupService.settle(deletion, modelContext: storeB.context, extraMirrors: []))
            #expect(original.currentCredentialValue(forKey: "JIRA_API_TOKEN") == "synthetic-retained-token")
            #expect(active.currentCredentialValue(forKey: "JIRA_API_TOKEN") == "synthetic-current-token")
            #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: storeB.context) == [oldOwner])
        }
    }
}
