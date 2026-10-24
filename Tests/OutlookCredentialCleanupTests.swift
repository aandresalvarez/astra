import Foundation
import Testing
import SwiftData
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Outlook credential cleanup", .serialized)
struct OutlookCredentialCleanupTests {
    @Test("Historical raw-trio storage is cleaned even with a separate generic generation", arguments: [false, true])
    func historicalLegacyStorageIsCompletelyCleaned(generation: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try StanfordOutlookMail.$registryURLOverride.withValue(root.appendingPathComponent("registry.json")) {
                let account = Connector(name: "Synthetic cleanup")
                account.applyStanfordOutlookDefaults()
                account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
                if generation { account.credentialNamespaceID = UUID() }
                // The removed writer's exact historical storage contract.
                for (key, value) in zip(OutlookCredentialIdentity.legacyTokenKeys,
                    ["synthetic-access", "synthetic-refresh", "2000000000"]) {
                    try #require(KeychainService.save(key: key, value: value, connectorID: account.id))
                }
                StanfordOutlookMailRegistry.upsert(connector: account)
                try #require(KeychainService.load(key: StanfordOutlookMail.refreshTokenKey, connectorID: account.id) == "synthetic-refresh")
                try #require(account.keychainCleanup.run())
                for key in OutlookCredentialIdentity.tokenKeys {
                    #expect(KeychainService.load(key: key, connectorID: account.id) == nil)
                }
                #expect(StanfordOutlookMailRegistry.entries().isEmpty)
            }
        }
    }

    @Test("A renewal lease prevents both generic and OAuth deletion until settled")
    func heldLeaseDefersAllDeletion() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let account = Connector(name: "Synthetic leased session")
            account.applyStanfordOutlookDefaults()
            account.credentialNamespaceID = UUID()
            let generic = try #require(account.credentialNamespaceID)
            try #require(KeychainService.save(key: "OTHER", value: "generic", connectorID: generic))
            try #require(KeychainService.save(key: StanfordOutlookMail.refreshTokenKey, value: "refresh", connectorID: account.id))
            var lease: KeychainOAuthSessionLease? = try .acquire(namespaceID: account.id)
            #expect(throws: KeychainOAuthSessionLease.Failure.self) { try KeychainOAuthSessionLease.acquire(namespaceID: account.id) }
            #expect(!KeychainService.deleteAll(facts: account.keychainCleanup.secretFacts, sparing: []))
            #expect(KeychainService.load(key: "OTHER", connectorID: generic) == "generic")
            #expect(KeychainService.load(key: StanfordOutlookMail.refreshTokenKey, connectorID: account.id) == "refresh")
            withExtendedLifetime(lease) {}
            lease = nil
            #expect(KeychainService.deleteAll(facts: account.keychainCleanup.secretFacts, sparing: []))
            #expect(KeychainService.load(key: "OTHER", connectorID: generic) == nil)
            #expect(KeychainService.load(key: StanfordOutlookMail.refreshTokenKey, connectorID: account.id) == nil)
        }
    }

    @Test("Cleanup ownership includes legacy OAuth without changing generic reads")
    func legacyOwnershipIsSeparateFromReadFallback() throws {
        let account = Connector(name: "Owned")
        account.applyStanfordOutlookDefaults()
        account.credentialNamespaceID = UUID()
        let facts = ConnectorSecretFacts(connector: account)
        let logical = KeychainSecretStore.connectorEntityID(for: account.id)
        #expect(!KeychainSecretStore.connectorEntityIDs(for: facts).contains(logical))
        #expect(try #require(KeychainSecretStore.ownedConnectorEntityIDs(for: facts)).contains(logical))
        account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
        #expect(!KeychainSecretStore.ownedConnectorEntityIDs(for: .init(connector: account))!.contains(logical))
        account.outlookCredentialFormat = "future-unknown"
        #expect(KeychainSecretStore.ownedConnectorEntityIDs(for: .init(connector: account)) == nil)
        #expect(ConnectorCredentialCleanup.Ownership([account]).hasUnknownOAuthOwnership)
    }

    @Test("A generic staging rollback never deletes the live legacy authorization")
    func genericRollbackDoesNotOwnLegacyOAuth() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let account = Connector(name: "Rollback")
            account.applyStanfordOutlookDefaults()
            try #require(KeychainService.save(key: StanfordOutlookMail.refreshTokenKey, value: "accepted-refresh", connectorID: account.id))
            var staged = account.keychainCleanup
            staged.credentialNamespaceID = UUID()
            staged.includesOutlookCredentials = false
            try #require(KeychainService.save(key: "OTHER", value: "staged", connectorID: staged.credentialNamespaceID!))
            #expect(KeychainService.deleteAll(facts: staged.secretFacts, sparing: []))
            #expect(KeychainService.load(key: StanfordOutlookMail.refreshTokenKey, connectorID: account.id) == "accepted-refresh")
        }
    }

    @Test("Old cleanup records retain legacy ownership after decoding")
    func oldRecordDecode() throws {
        let account = Connector(name: "Old record")
        account.applyStanfordOutlookDefaults()
        let encoded = try JSONEncoder().encode(account.keychainCleanup)
        var raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        raw.removeValue(forKey: "outlookCredentialFormat")
        raw.removeValue(forKey: "includesOutlookCredentials")
        let decoded = try JSONDecoder().decode(ConnectorKeychainCleanup.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(decoded.secretFacts.includesOutlookCredentials)
        #expect(decoded.secretFacts.outlookCredentialFormat == nil)
        #expect(try #require(KeychainSecretStore.ownedConnectorEntityIDs(for: decoded.secretFacts)).contains(KeychainSecretStore.connectorEntityID(for: account.id)))
    }

    @Test("Recovery mirror ownership preserves exact and unknown OAuth formats", arguments: ["generation-v1", "future-unknown", "legacy"])
    func mirrorPreservesFormat(format: String) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let accountID = UUID(), namespace = UUID()
        let mirror = env.disk.root.appendingPathComponent("oauth-mirror.json")
        var entry: [String: Any] = ["id": accountID.uuidString, "name": "Mirror", "serviceType": OutlookCredentialIdentity.serviceType,
                                   "credentialNamespaceID": namespace.uuidString]
        if format != "legacy" { entry["outlookCredentialFormat"] = format }
        try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "connectors": [entry]]).write(to: mirror)
        let captured = try #require(ConnectorCredentialCleanup.connectorsInStoredMirrors(modelContext: env.context, extraMirrors: [mirror.path]))
        let owner = try #require(captured.owners.first { $0.connectorID == accountID })
        #expect(owner.outlookCredentialFormat == (format == "legacy" ? nil : format))
        let ownership = ConnectorCredentialCleanup.Ownership([], retained: [owner])
        #expect(ownership.hasUnknownOAuthOwnership == (format == "future-unknown"))
        #expect(ownership.namespaces.contains(KeychainSecretStore.connectorEntityID(for: accountID)) == (format == "legacy"))
    }

    @Test("The actual generation transaction discards only staged generic credentials")
    func actualTransactionRollbackPreservesLegacy() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let account = Connector(name: "Transaction rollback")
            account.applyStanfordOutlookDefaults()
            account.workspace = env.workspace
            account.credentialNamespaceID = UUID()
            env.context.insert(account)
            try env.context.save()
            try #require(KeychainService.save(key: StanfordOutlookMail.refreshTokenKey, value: "accepted-refresh", connectorID: account.id))
            let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
                keeping: [], replacing: ["OTHER"], modelContext: env.context, legacyHandling: .preservePending)
            prepared.noteWriteAttempt()
            try #require(KeychainService.save(key: "OTHER", value: "unpublished", connectorID: prepared.namespaceID))
            prepared.discard()
            #expect(KeychainService.load(key: "OTHER", connectorID: prepared.namespaceID) == nil)
            #expect(KeychainService.load(key: StanfordOutlookMail.refreshTokenKey, connectorID: account.id) == "accepted-refresh")
        }
    }
}
