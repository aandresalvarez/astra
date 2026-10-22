import Foundation
import Testing
import ASTRACore

@Suite("Outlook credential identity")
struct OutlookCredentialIdentityTests {
    @Test("Pre-patch OAuth stays on its exact logical identity despite a generic generation")
    func legacyDoesNotFollowGenericGeneration() {
        let account = UUID()
        let generation = UUID()
        for format in [nil, ""] as [String?] {
            #expect(OutlookCredentialIdentity.resolve(accountID: account,
                credentialNamespaceID: generation, format: format) == .legacy(account))
            #expect(OutlookCredentialIdentity.resolve(accountID: account,
                credentialNamespaceID: nil, format: format)?.namespaceID == account)
        }
    }

    @Test("New OAuth resolves only its published generation")
    func explicitGeneration() {
        let account = UUID()
        let generation = UUID()
        #expect(OutlookCredentialIdentity.resolve(accountID: account, credentialNamespaceID: generation,
            format: OutlookCredentialIdentity.generationFormat) == .generation(generation))
        #expect(OutlookCredentialIdentity.resolve(accountID: account, credentialNamespaceID: nil,
            format: OutlookCredentialIdentity.generationFormat) == nil)
    }

    @Test("An unknown storage contract never falls back to the logical identity", arguments: ["generation-v2", "legacy", " generation-v1 "])
    func unsupportedFormatFailsClosed(format: String) {
        #expect(OutlookCredentialIdentity.resolve(accountID: UUID(), credentialNamespaceID: UUID(), format: format) == nil)
    }
}
