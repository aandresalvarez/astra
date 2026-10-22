import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Outlook authorization generation transactions", .serialized)
struct OutlookCredentialGenerationTests {
    private func bundle(_ access: String = "accepted-access") -> OutlookOAuthBundle {
        .init(tenantDomain: "tenant.example", clientID: "synthetic-client", principalID: "accepted-principal",
              accessToken: access, refreshToken: "accepted-refresh", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private func account(in env: PluginAddCommitTests.Fixture, legacy: Bool = false) throws -> Connector {
        let account = Connector(name: "Outlook generation")
        account.applyStanfordOutlookDefaults()
        account.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: "tenant.example")
        account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
        account.setConfigValue(StanfordOutlookMail.accountIDKey, value: "accepted-principal")
        account.workspace = env.workspace
        account.credentialNamespaceID = UUID()
        if !legacy { account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat }
        env.context.insert(account)
        try env.context.save()
        if legacy {
            for (key, value) in zip(OutlookCredentialIdentity.legacyTokenKeys, ["accepted-access", "accepted-refresh", "2000000000"]) {
                try #require(KeychainService.save(key: key, value: value, connectorID: account.id))
            }
        } else {
            let session = try OutlookOAuthVaultSession(reference: .generation(account.credentialNamespaceID!))
            try #require(try session.save(bundle()))
        }
        return account
    }

    private func authorization(_ account: Connector) throws -> OutlookOAuthBundle? {
        let reference = try #require(OutlookCredentialIdentity.resolve(accountID: account.id,
            credentialNamespaceID: account.credentialNamespaceID, format: account.outlookCredentialFormat))
        let session = try OutlookOAuthVaultSession(reference: reference)
        return try session.load(tenantDomain: account.outlookTenantDomain, clientID: account.outlookClientID,
            principalID: account.configValue(StanfordOutlookMail.accountIDKey))
    }

    @Test("An actual generic credential edit preserves accepted Outlook authorization", arguments: [false, true])
    func genericEditPreservesOAuth(legacy: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(in: env, legacy: legacy)
            let accepted = PluginAccountRecord(current)
            let previous = current.credentialNamespaceID
            try #require(try ConnectorCredentialEditor.save("additional-service-token", forKey: "EXTRA_TOKEN", on: current,
                modelContext: env.context, allowUserInteraction: false).isSaved)
            #expect(current.credentialNamespaceID != previous)
            #expect(current.outlookCredentialFormat == (legacy ? nil : OutlookCredentialIdentity.generationFormat))
            #expect(try authorization(current) == bundle())
            #expect(try authorization(accepted.makeAccount()) == bundle())
            #expect(!current.credentialKeys.contains(OutlookOAuthBundle.storageKey))
        }
    }

    @Test("Actual duplication independently copies legacy and generation OAuth", arguments: [false, true])
    func duplicationCopiesExactAuthorization(legacy: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let source = try account(in: env, legacy: legacy)
            let copy = try ConnectorCredentialDuplication.duplicate(source, in: env.workspace, modelContext: env.context)
            #expect(copy.id != source.id)
            #expect(copy.credentialNamespaceID != source.credentialNamespaceID)
            #expect(copy.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
            #expect(try authorization(copy) == bundle())
            let reference = try #require(OutlookCredentialIdentity.resolve(accountID: source.id,
                credentialNamespaceID: source.credentialNamespaceID, format: source.outlookCredentialFormat))
            do {
                let session = try OutlookOAuthVaultSession(reference: reference)
                try #require(try session.save(bundle("source-renewed-access")))
            }
            #expect(try authorization(source)?.accessToken == "source-renewed-access")
            #expect(try authorization(copy)?.accessToken == "accepted-access")
            #expect(copy.credentialKeys.isEmpty)
        }
    }

    @Test("A discarded copied generation removes its private bundle and preserves the accepted one")
    func rollbackDoesNotTouchAcceptedBundle() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(in: env)
            let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: current, isNew: false,
                keeping: [], replacing: [], modelContext: env.context)
            do {
                let staged = try OutlookOAuthVaultSession(reference: .generation(prepared.namespaceID))
                #expect(try staged.load(tenantDomain: "tenant.example", clientID: "synthetic-client", principalID: "accepted-principal") == bundle())
            }
            prepared.discard()
            #expect(KeychainService.load(key: OutlookOAuthBundle.storageKey, connectorID: prepared.namespaceID) == nil)
            #expect(try authorization(current) == bundle())
        }
    }

    @Test("A raw settings-only copy carries an empty independent OAuth namespace", arguments: [false, true])
    func fieldsOnlyCopyCannotInherit(legacy: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let source = try account(in: env, legacy: legacy)
            let copy = CapabilitySharing.makeWorkspaceCopy(source, in: env.workspace)
            #expect(copy.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
            #expect(copy.credentialNamespaceID != source.credentialNamespaceID)
            #expect(try authorization(copy) == nil)
            #expect(try authorization(source) == bundle())
        }
    }

    @Test("Unreadable or unknown OAuth ownership prevents a generic cutover", arguments: ["unknown", "corrupt", "busy"])
    func unsafeSourcePreventsPublication(mode: String) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(in: env)
            let original = current.credentialNamespaceID
            var held: KeychainOAuthSessionLease?
            if mode == "unknown" {
                current.outlookCredentialFormat = "future-unknown"
                try env.context.save()
            } else if mode == "corrupt" {
                try #require(KeychainService.save(key: OutlookOAuthBundle.storageKey, value: "{corrupt", connectorID: original!))
            } else {
                held = try .acquire(namespaceID: original!)
            }
            #expect(throws: (any Error).self) {
                try ConnectorCredentialEditor.save("additional-service-token", forKey: "EXTRA_TOKEN", on: current,
                    modelContext: env.context, allowUserInteraction: false)
            }
            #expect(current.credentialNamespaceID == original)
            #expect(!env.context.hasChanges)
            withExtendedLifetime(held) {}
        }
    }

    @Test("Explicit sign-out stages an empty generation without mutating the accepted authorization")
    func signOutIsReplacementNotDeletion() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(in: env)
            let accepted = PluginAccountRecord(current)
            let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: current, isNew: false,
                keeping: [], replacing: [], modelContext: env.context, outlookChange: .signOut)
            prepared.apply(to: current)
            #expect(current.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
            #expect(try authorization(current) == nil)
            #expect(try authorization(accepted.makeAccount()) == bundle())
            env.context.rollback()
            prepared.discard()
        }
    }

    @Test("Retired generic generations can be collected while legacy OAuth remains live")
    func collectorReclaimsOnlyRetiredGenericGeneration() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(in: env, legacy: true)
            let original = try #require(current.credentialNamespaceID)
            current.credentialKeys = ["EXTRA_TOKEN"]
            current.credentialValues = [""]
            try env.context.save()
            try #require(KeychainService.save(key: "EXTRA_TOKEN", value: "old-service-token", connectorID: original))
            try #require(try ConnectorCredentialEditor.save("new-service-token", forKey: "EXTRA_TOKEN", on: current,
                modelContext: env.context, allowUserInteraction: false).isSaved)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
            _ = journal.resumePending(modelContext: env.context)
            #expect(KeychainService.load(key: "EXTRA_TOKEN", connectorID: original) == nil)
            #expect(current.currentCredentialValue(forKey: "EXTRA_TOKEN") == "new-service-token")
            #expect(try authorization(current) == bundle())
            #expect(try !journal.pending().contains { $0.credentialNamespaceID == original })
        }
    }

    @Test("Repeated Add retains resolved OAuth accounts even without a selected binding", arguments: [true, false])
    func repeatedAddPreservesOAuthStorageFormat(bound: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.localTools = []
            package.connectors[0].serviceType = OutlookCredentialIdentity.serviceType
            package.connectors[0].authMethod = StanfordOutlookMail.authMethod
            package.connectors[0].credentialHints = []
            package.connectors[0].configHints = []
            try env.disk.library.install(package)
            try env.installer.enable(package, in: env.workspace, modelContext: env.context)
            let current = try #require(env.workspace.connectors.first { $0.originPackageID == package.id })
            current.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: "tenant.example")
            current.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
            current.setConfigValue(StanfordOutlookMail.accountIDKey, value: "accepted-principal")
            try env.context.save()
            let namespace = try #require(current.credentialNamespaceID)
            do {
                let session = try OutlookOAuthVaultSession(reference: .generation(namespace))
                try #require(try session.save(bundle()))
            }
            if !bound {
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
                WorkspaceCapabilityActivation.unbind(current, from: activation)
                try env.context.save()
            }
            let component = CapabilityResourceOrigin.componentID(for: package.connectors[0])
            try env.installer.enable(package, in: env.workspace, modelContext: env.context,
                baseURLOverrides: [component: "https://graph.microsoft.com/v1.0/changed"])
            #expect(env.workspace.connectors.filter { $0.originPackageID == package.id }.map(\.id) == [current.id])
            #expect(current.outlookTenantDomain == "tenant.example")
            #expect(current.outlookClientID == "synthetic-client")
            #expect(current.configValue(StanfordOutlookMail.accountIDKey) == "accepted-principal")
            #expect(current.credentialNamespaceID == namespace)
            #expect(current.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
            #expect(try authorization(current) == bundle())
        }
    }
}
