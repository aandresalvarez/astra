import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
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
