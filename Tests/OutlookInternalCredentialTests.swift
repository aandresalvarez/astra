import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("App-owned Outlook credentials", .serialized)
struct OutlookInternalCredentialTests {
    @Test("Generic declarations cannot read, overwrite or delete OAuth slots", arguments: OutlookCredentialIdentity.tokenKeys + [OutlookCredentialIdentity.formatKey])
    func genericCredentialsCannotTouchOAuth(key: String) throws {
        let account = Connector(name: "Outlook")
        account.applyStanfordOutlookDefaults()
        account.credentialNamespaceID = UUID()
        account.credentialKeys = [key, "EXTRA_KEY"]
        let facts = ConnectorSecretFacts(connector: account)
        let store = MockSecretStore()
        let namespace = try #require(KeychainSecretStore.connectorEntityIDs(for: facts).first)
        #expect(store.save(key: key, value: "synthetic-internal", entityID: namespace, label: nil))
        #expect(store.save(key: "EXTRA_KEY", value: "ordinary-secret", entityID: namespace, label: nil))
        #expect(ConnectorSecretPersistence.readCredential(key: key, facts: facts, store: store) == .unavailable)
        #expect(ConnectorSecretPersistence.loadAllCredentials(keys: account.credentialKeys, facts: facts, store: store) == ["EXTRA_KEY": "ordinary-secret"])
        #expect(!ConnectorSecretPersistence.saveCredential("overwrite", key: key, facts: facts, store: store))
        #expect(!ConnectorSecretPersistence.deleteCredential(key: key, facts: facts, store: store))
        #expect(store.load(key: key, entityID: namespace) == "synthetic-internal")
        #expect(ConnectorCredentialAdmission.evaluate(key: key, value: "replacement", serviceType: account.serviceType).verdict == .reservedInternalKey)
    }

    @Test("An unbound OAuth account cannot bypass token lifetime ownership by changing service")
    func outlookServiceIsFixed() {
        let account = Connector(name: "Outlook")
        account.applyStanfordOutlookDefaults()
        let generation = UUID()
        account.credentialNamespaceID = generation
        account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
        #expect(!WorkspaceCapabilityActivation.canChangeService(of: account))
        #expect(!WorkspaceCapabilityActivation.changeService(of: account, to: "custom"))
        #expect(account.isStanfordOutlookMail)
        #expect(account.credentialNamespaceID == generation)
        #expect(account.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
    }

    @Test("The facts-based Keychain API cannot bypass the generic credential boundary")
    func realVaultBoundary() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let account = Connector(name: "Outlook")
            account.applyStanfordOutlookDefaults()
            account.credentialNamespaceID = UUID()
            let key = OutlookOAuthBundle.storageKey
            #expect(KeychainService.save(key: key, value: "dedicated-oauth-slot", connectorID: account.credentialNamespaceID!))
            // The same namespace cannot expose an OAuth slot under a
            // different service's generic credential API.
            account.serviceType = "custom"
            #expect(ConnectorCredentialAdmission.evaluate(key: key, value: "replacement", serviceType: "custom").verdict == .reservedInternalKey)
            #expect(KeychainService.load(key: key, facts: ConnectorSecretFacts(connector: account)) == nil)
            #expect(!KeychainService.exists(key: key, facts: ConnectorSecretFacts(connector: account)))
            #expect(!KeychainService.save(key: key, value: "overwrite", facts: ConnectorSecretFacts(connector: account)))
            #expect(!KeychainService.delete(key: key, facts: ConnectorSecretFacts(connector: account)))
            #expect(KeychainService.load(key: key, connectorID: account.credentialNamespaceID!) == "dedicated-oauth-slot")
        }
    }
}
