import Foundation
import Testing
import ASTRACore

@Suite("Outlook atomic authorization bundle")
struct OutlookOAuthBundleTests {
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Refresh preserves authorization identity and an omitted refresh token")
    func refreshPreservesIdentity() {
        let original = bundle()
        let changed = original.refreshed(accessToken: "synthetic-new-access", refreshToken: nil, expiresAt: expiry.addingTimeInterval(60))
        #expect(changed.accessToken == "synthetic-new-access")
        #expect(changed.refreshToken == original.refreshToken)
        #expect(changed.principalID == original.principalID)
        #expect(changed.clientID == original.clientID)
        #expect(changed.tenantDomain == original.tenantDomain)
        #expect(changed.expiresAt != original.expiresAt)
        #expect(original.accessToken == "synthetic-access")
        #expect(original.refreshed(accessToken: "next", refreshToken: "rotated", expiresAt: expiry).refreshToken == "rotated")
    }

    @Test("A new authorization never inherits a previous login's refresh token")
    func newAuthorizationDoesNotMixGrants() {
        let next = OutlookOAuthBundle(tenantDomain: "tenant.example", clientID: "client", principalID: "another-principal",
            accessToken: "next-access", refreshToken: nil, expiresAt: expiry)
        #expect(next.refreshToken == nil)
        #expect(!next.matches(tenantDomain: "tenant.example", clientID: "client", principalID: "principal"))
    }

    @Test("The bundle round-trips as one value and refuses mismatched or unsupported context")
    func roundTripAndContext() throws {
        let original = bundle()
        #expect(try JSONDecoder().decode(OutlookOAuthBundle.self, from: JSONEncoder().encode(original)) == original)
        #expect(original.matches(tenantDomain: "tenant.example", clientID: "client", principalID: "principal"))
        #expect(!original.matches(tenantDomain: "other.example", clientID: "client", principalID: "principal"))
        #expect(!original.matches(tenantDomain: "tenant.example", clientID: "other-client", principalID: "principal"))
        #expect(!bundle(version: 99).isSupported)
        #expect(!bundle(version: 99).refreshed(accessToken: "next", refreshToken: nil, expiresAt: expiry).isSupported)
    }

    private func bundle(version: Int = 1) -> OutlookOAuthBundle {
        OutlookOAuthBundle(tenantDomain: "tenant.example", clientID: "client", principalID: "principal",
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: expiry, version: version)
    }
}
