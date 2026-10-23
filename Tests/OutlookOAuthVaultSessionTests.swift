import Foundation
import Testing
import Security
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Outlook OAuth vault sessions", .serialized)
struct OutlookOAuthVaultSessionTests {
    private func bundle(access: String = "access", refresh: String? = "refresh") -> OutlookOAuthBundle {
        .init(tenantDomain: "tenant.example", clientID: "client", principalID: "principal",
              accessToken: access, refreshToken: refresh, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test("One atomic bundle owns a new generation without any token fields in the model")
    func generationRoundtrip() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let account = Connector(name: "New OAuth")
            account.applyStanfordOutlookDefaults()
            account.credentialNamespaceID = UUID()
            account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
            let reference = try #require(OutlookCredentialIdentity.resolve(accountID: account.id,
                credentialNamespaceID: account.credentialNamespaceID, format: account.outlookCredentialFormat))
            let session = try OutlookOAuthVaultSession(reference: reference)
            #expect(try session.save(bundle()))
            #expect(try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal") == bundle())
            #expect(account.credentialKeys.isEmpty)
            for key in OutlookCredentialIdentity.tokenKeys {
                #expect(KeychainService.load(key: key, connectorID: account.id) == nil)
            }
            for key in OutlookCredentialIdentity.legacyTokenKeys {
                #expect(KeychainService.load(key: key, connectorID: reference.namespaceID) == nil)
            }
        }
    }

    @Test("Missing new-generation bundles never inherit logical or raw legacy token fields")
    func generationNeverFallsBack() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let logical = UUID(), generation = UUID()
            for namespace in [logical, generation] {
                for (key, value) in zip(OutlookCredentialIdentity.legacyTokenKeys, ["wrong-access", "wrong-refresh", "2000000000"]) {
                    try #require(KeychainService.save(key: key, value: value, connectorID: namespace))
                }
            }
            let session = try OutlookOAuthVaultSession(reference: .generation(generation))
            #expect(try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal") == nil)
        }
    }

    @Test("Only absent legacy bundles permit exact-namespace old-field migration")
    func legacyFallbackAndBundlePriority() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let namespace = UUID()
            for (key, value) in zip(OutlookCredentialIdentity.legacyTokenKeys, ["legacy-access", "legacy-refresh", "2000000000"]) {
                try #require(KeychainService.save(key: key, value: value, connectorID: namespace))
            }
            let session = try OutlookOAuthVaultSession(reference: .legacy(namespace))
            #expect(try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal")?.accessToken == "legacy-access")
            #expect(try session.save(bundle(access: "bundle-access")))
            #expect(try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal")?.accessToken == "bundle-access")
            try #require(KeychainService.save(key: OutlookOAuthBundle.storageKey, value: "{corrupt", connectorID: namespace))
            #expect(throws: OutlookOAuthVaultSession.Failure.self) {
                try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal")
            }
            #expect(throws: OutlookOAuthVaultSession.Failure.self) { try session.save(bundle()) }
            #expect(KeychainService.load(key: OutlookOAuthBundle.storageKey, connectorID: namespace) == "{corrupt")
        }
    }

    @Test("A bundle is refused under another tenant, client or principal")
    func contextIsImmutable() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let session = try OutlookOAuthVaultSession(reference: .generation(UUID()))
            try #require(try session.save(bundle()))
            for context in [("other", "client", "principal"), ("tenant.example", "other", "principal"), ("tenant.example", "client", "other")] {
                #expect(throws: OutlookOAuthVaultSession.Failure.self) {
                    try session.load(tenantDomain: context.0, clientID: context.1, principalID: context.2)
                }
            }
            for context in [("other", "client", "principal"), ("tenant.example", "other", "principal"), ("tenant.example", "client", "other")] {
                let switched = OutlookOAuthBundle(tenantDomain: context.0, clientID: context.1, principalID: context.2,
                    accessToken: "other-authorization", refreshToken: "other-refresh", expiresAt: Date())
                #expect(throws: OutlookOAuthVaultSession.Failure.self) { try session.save(switched) }
            }
            let invalid = OutlookOAuthBundle(tenantDomain: "tenant.example", clientID: "client", principalID: "principal",
                accessToken: "invalid", refreshToken: nil, expiresAt: Date(), version: 2)
            #expect(throws: OutlookOAuthVaultSession.Failure.self) { try session.save(invalid) }
            #expect(try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal") == bundle())
        }
    }

    @Test("Refreshing a bundle updates the existing keychain record in place")
    func refreshKeepsPersistentItemIdentity() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let namespace = UUID()
            let session = try OutlookOAuthVaultSession(reference: .generation(namespace))
            try #require(try session.save(bundle()))
            let path = try #require(AstraSecureKeychainStore.keychainPathOverride)
            var handle: SecKeychain?
            try #require(SecKeychainOpen(path, &handle) == errSecSuccess)
            let keychain = try #require(handle)
            func persistentIdentity() throws -> Data {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: KeychainSecretStore.connectorEntityID(for: namespace),
                    kSecAttrAccount as String: OutlookOAuthBundle.storageKey,
                    kSecMatchSearchList as String: [keychain], kSecReturnPersistentRef as String: true]
                var result: CFTypeRef?
                try #require(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
                return try #require(result as? Data)
            }
            let original = try persistentIdentity()
            try #require(try session.save(bundle(access: "renewed", refresh: "rotated")))
            #expect(try persistentIdentity() == original)
            #expect(try session.load(tenantDomain: "tenant.example", clientID: "client", principalID: "principal")?.accessToken == "renewed")
        }
    }
}
