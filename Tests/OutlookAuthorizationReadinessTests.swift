import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Outlook authorization readiness", .serialized)
struct OutlookAuthorizationReadinessTests {
    @Test("Access-only authorization is connected only while the backend can use it", arguments: [-3600.0, 60.0, 3600.0])
    func accessOnlyExpiry(remaining: Double) async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let bundle = OutlookOAuthBundle(tenantDomain: fixture.initial.tenantDomain,
                clientID: fixture.initial.clientID, principalID: fixture.initial.principalID,
                accessToken: "access-only", refreshToken: nil, expiresAt: Date().addingTimeInterval(remaining))
            // Finish the credential producer before exercising Sign Out.
            try store(bundle, namespace: fixture.account.credentialNamespaceID!)
            #expect(fixture.account.hasOutlookAuthorization == (remaining > 120))
            #expect(fixture.account.hasStoredOutlookAuthorization)
            let transport = OutlookBackendHTTPStub { _ in throw URLError(.badServerResponse) }
            do {
                let token = try await StanfordOutlookMailAuthService(transport: transport).validAccessToken(connector: fixture.account)
                #expect(remaining > 120)
                #expect(token == "access-only")
            } catch StanfordOutlookMailError.missingRefreshToken {
                #expect(remaining <= 120)
            }
            #expect(await transport.calls().isEmpty)
            try OutlookAuthorizationEditor.signOut(fixture.account, modelContext: fixture.env.context)
            #expect(!fixture.account.hasStoredOutlookAuthorization)
            #expect(!fixture.account.hasOutlookAuthorization)
        }
    }

    @Test("Presentation and backend share the exact refresh safety margin", arguments: [119.0, 120.0, 121.0])
    func exactMargin(remaining: Double) {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiry = now.addingTimeInterval(remaining)
        let status = OutlookAuthorizationReadiness(isStored: true, canRefresh: false, accessTokenExpiresAt: expiry)
        #expect(status.canReadMail(at: now) == (remaining > 120))
        #expect(OutlookAuthorizationReadiness.canUseAccessToken(expiresAt: expiry, at: now) == status.canReadMail(at: now))
    }

    private func store(_ bundle: OutlookOAuthBundle, namespace: UUID) throws {
        let session = try OutlookOAuthVaultSession(reference: .generation(namespace))
        #expect(try session.save(bundle))
    }

    @Test("A refreshable authorization remains connected when its access token expires")
    func refreshableExpiry() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: true)
            defer { fixture.removeFiles() }
            #expect(fixture.account.hasOutlookAuthorization)
        }
    }
}
