import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Capability rail prerequisite status signature")
struct CapabilityRailPrerequisiteStatusSignatureTests {
    @Test("Gaining or changing an authorization URL invalidates the cached snapshot")
    func authorizationURLParticipatesInSignature() {
        let id = CommonCLIPrerequisites.githubAuth.id
        let withoutURL = CapabilityRailPrerequisiteStatusSignature(
            id: id,
            status: .authorizationRequired(detail: "SAML SSO required", authorizationURL: nil)
        )
        let withURL = CapabilityRailPrerequisiteStatusSignature(
            id: id,
            status: .authorizationRequired(
                detail: "SAML SSO required",
                authorizationURL: URL(string: "https://github.com/orgs/example/sso")
            )
        )
        let withOtherURL = CapabilityRailPrerequisiteStatusSignature(
            id: id,
            status: .authorizationRequired(
                detail: "SAML SSO required",
                authorizationURL: URL(string: "https://github.com/orgs/other/sso")
            )
        )

        // The rail's Authorize affordance is driven by the URL, so a snapshot keyed on the
        // detail alone would keep serving a stale (or missing) destination.
        #expect(withoutURL != withURL)
        #expect(withURL != withOtherURL)
        #expect(withURL == CapabilityRailPrerequisiteStatusSignature(
            id: id,
            status: .authorizationRequired(
                detail: "SAML SSO required",
                authorizationURL: URL(string: "https://github.com/orgs/example/sso")
            )
        ))
    }

    @Test("Distinct health states produce distinct signatures")
    func distinctStatesProduceDistinctSignatures() {
        let id = CommonCLIPrerequisites.githubAuth.id
        let statuses: [HealthStatus] = [
            .healthy(path: "/opt/homebrew/bin/gh", version: "2.62.0"),
            .healthy(path: "/opt/homebrew/bin/gh", version: "2.63.0"),
            .unverified(path: "/opt/homebrew/bin/gh", detail: "No repository target was resolved."),
            .unauthenticated(detail: "No account is signed in."),
            .authorizationRequired(detail: "SAML SSO required", authorizationURL: nil),
            .unresponsive(detail: "Timed out."),
            .missingBinary
        ]
        let signatures = Set(statuses.map { CapabilityRailPrerequisiteStatusSignature(id: id, status: $0) })

        #expect(signatures.count == statuses.count)
    }
}
