import Foundation
import Testing
@testable import ASTRA

@Suite("Stanford Outlook Mail")
@MainActor
struct StanfordOutlookMailTests {
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
