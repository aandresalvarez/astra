import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence
import ASTRACore

@Suite("Stanford Outlook Mail")
@MainActor
struct StanfordOutlookMailTests {
    @Test("ConnectorOutlookFacts preserves first-match config semantics for duplicate keys")
    func factsPreserveFirstMatchConfigSemanticsForDuplicateKeys() {
        // Regression test: ConnectorOutlookFacts/OutlookMailConnectionAdapter
        // used to build facts from `connector.config` (a `[String: String]`
        // collapsed via `zip(configKeys, configValues)`, last-wins), while
        // `Connector.configValue(_:)` resolves duplicate keys via
        // `firstIndex(of:)` (first-wins). A connector with duplicate config
        // rows would then authenticate against a different tenant/client
        // than the live `self.outlookTenantDomain`/`.outlookClientID` would.
        let connector = Connector(name: "Stanford Outlook Mail")
        connector.applyStanfordOutlookDefaults()
        // Simulate a duplicated config row (e.g. from a corrupted import).
        connector.configKeys.append("ASTRA_MAIL_TENANT_DOMAIN")
        connector.configValues.append("stale-duplicate.example.edu")

        let facts = ConnectorOutlookFacts(
            id: connector.id,
            name: connector.name,
            serviceType: connector.serviceType,
            configKeys: connector.configKeys,
            configValues: connector.configValues
        )

        // Reconstruct exactly as OutlookMailConnectionAdapter.testConnection does.
        let scratch = Connector(name: facts.name, serviceType: facts.serviceType)
        scratch.id = facts.id
        scratch.configKeys = facts.configKeys
        scratch.configValues = facts.configValues

        #expect(scratch.configValue("ASTRA_MAIL_TENANT_DOMAIN") == connector.configValue("ASTRA_MAIL_TENANT_DOMAIN"))
        #expect(scratch.outlookTenantDomain == connector.outlookTenantDomain)
        #expect(connector.configValue("ASTRA_MAIL_TENANT_DOMAIN") != "stale-duplicate.example.edu")
    }

    @Test("Registry removal reports whether the entry is gone, and never rewrites a registry it can't read")
    func registryRemovalReportsItsResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-mail-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let registry = root.appendingPathComponent("mail-accounts.json")
        let connector = Connector(name: "Stanford Outlook Mail")
        connector.applyStanfordOutlookDefaults()
        try StanfordOutlookMail.$registryURLOverride.withValue(registry) {
            // Nothing registered: nothing to remove.
            #expect(StanfordOutlookMailRegistry.remove(connectorID: connector.id))

            StanfordOutlookMailRegistry.upsert(connector: connector)
            #expect(StanfordOutlookMailRegistry.entries().map(\.connectorID) == [connector.id.uuidString])
            // A registry that can't be rewritten keeps the entry and says so,
            // and so does the connector's cleanup, though its credentials
            // cleared. A temporary keychain makes that credential part succeed.
            let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
            let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
            AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
            defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: []) }
            try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
                try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
                    #expect(!StanfordOutlookMailRegistry.remove(connectorID: connector.id))
                    #expect(!connector.keychainCleanup.run(sparing: [], keepRegistryEntry: false))
                    #expect(connector.keychainCleanup.run(sparing: [], keepRegistryEntry: true))
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
                    #expect(connector.keychainCleanup.run(sparing: [], keepRegistryEntry: false))
                }
            }
            #expect(StanfordOutlookMailRegistry.entries().isEmpty)

            // A link to a registry holding the entry: an atomic write would
            // replace the link and leave the entry in its target.
            let target = root.appendingPathComponent("managed.json")
            StanfordOutlookMailRegistry.upsert(connector: connector)
            try FileManager.default.moveItem(at: registry, to: target)
            try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: target)
            let linked = try Data(contentsOf: target)
            #expect(!StanfordOutlookMailRegistry.remove(connectorID: connector.id))
            #expect(try Data(contentsOf: target) == linked)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: registry.path)) != nil)
            try FileManager.default.removeItem(at: registry)
            try FileManager.default.moveItem(at: target, to: registry)
            #expect(StanfordOutlookMailRegistry.remove(connectorID: connector.id))

            // A dangling link is a registry that can't be verified.
            try FileManager.default.removeItem(at: registry)
            try FileManager.default.createSymbolicLink(
                at: registry, withDestinationURL: root.appendingPathComponent("gone.json")
            )
            #expect(!StanfordOutlookMailRegistry.remove(connectorID: connector.id))
            try FileManager.default.removeItem(at: registry)

            // An unreadable registry is left as it is, not emptied.
            try Data("not json".utf8).write(to: registry)
            #expect(!StanfordOutlookMailRegistry.remove(connectorID: connector.id))
            #expect(try Data(contentsOf: registry) == Data("not json".utf8))
        }
    }

    @Test("Outlook connector defaults are OAuth without token env keys")
    func outlookConnectorDefaults() {
        let connector = Connector(name: "Stanford Outlook Mail")
        connector.applyStanfordOutlookDefaults()

        #expect(connector.serviceType == StanfordOutlookMail.serviceType)
        #expect(connector.authMethod == StanfordOutlookMail.authMethod)
        #expect(connector.baseURL == StanfordOutlookMail.graphBaseURL)
        #expect(connector.credentialKeys.isEmpty)
        #expect(connector.allEnvironmentVariables[StanfordOutlookMail.accessTokenKey] == nil)
        #expect(connector.configValue(StanfordOutlookMail.tenantDomainKey) == "stanford.edu")
        #expect(connector.configValue(StanfordOutlookMail.scopesKey).contains("Mail.Read"))
    }

    @Test("Tenant normalization keeps custom Stanford-family domains")
    func tenantNormalization() {
        #expect(StanfordOutlookMail.normalizeTenant("") == "stanford.edu")
        #expect(StanfordOutlookMail.normalizeTenant(" StanfordHealthCare.org ") == "stanfordhealthcare.org")
    }

    @Test("Configured tenant state stays separate from default endpoint tenant")
    func configuredTenantState() {
        let connector = Connector(name: "Stanford Outlook Mail")
        connector.applyStanfordOutlookDefaults(defaultTenant: false)

        #expect(!connector.hasConfiguredOutlookTenantDomain)
        #expect(connector.configuredOutlookTenantDomain.isEmpty)
        #expect(connector.outlookTenantDomain == "stanford.edu")

        connector.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: " StanfordHealthCare.org ")

        #expect(connector.hasConfiguredOutlookTenantDomain)
        #expect(connector.configuredOutlookTenantDomain == "stanfordhealthcare.org")
        #expect(connector.outlookTenantDomain == "stanfordhealthcare.org")
    }
}
