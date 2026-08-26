import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAPersistence
@testable import ASTRAModels
@testable import ASTRA

/// The incident these rules exist for: a live Atlassian API token was pasted
/// into the REDCap connector's `REDCAP_API_TOKEN`, stored without complaint,
/// and then projected into an agent run that shipped it to redcap.stanford.edu.
/// Every test here pins one reason that would have stopped it.
@Suite("Connector Credential Admission")
struct ConnectorCredentialAdmissionTests {

    // A syntactically Atlassian-shaped value. Not a real token: the prefix is
    // public knowledge and the body is filler.
    private static let atlassianShaped =
        "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000111122223333444455556666"
    private static let redcapShaped = "0123456789ABCDEF0123456789ABCDEF"

    // MARK: The incident

    @Test("An Atlassian token is refused as a REDCap token")
    func atlassianTokenRefusedAsREDCapToken() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN",
            value: Self.atlassianShaped,
            serviceType: "redcap"
        )

        #expect(!decision.isAdmitted)
        guard case .foreignVendor(let vendor, let belongsTo, _) = decision.verdict else {
            Issue.record("Expected a foreign-vendor verdict, got \(decision.verdict)")
            return
        }
        #expect(vendor == "Atlassian")
        #expect(belongsTo == "redcap")
    }

    @Test("The rejection names the issuer without reproducing the value")
    func rejectionMessageNeverContainsTheValue() throws {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN",
            value: Self.atlassianShaped,
            serviceType: "redcap"
        )
        let message = try #require(decision.verdict.message(forKey: "REDCAP_API_TOKEN"))

        #expect(message.contains("Atlassian"))
        #expect(!message.contains(Self.atlassianShaped))
        #expect(!message.contains("ATATT3xFfGF0"))
        #expect(decision.verdict.auditReason == "foreign_vendor")
    }

    @Test("A well-formed REDCap token is admitted")
    func wellFormedREDCapTokenAdmitted() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN",
            value: Self.redcapShaped,
            serviceType: "redcap"
        )

        #expect(decision.isAdmitted)
        #expect(decision.verdict.message(forKey: "REDCAP_API_TOKEN") == nil)
    }

    @Test("Surrounding whitespace is stripped rather than stored")
    func pastedWhitespaceIsNormalizedAway() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN",
            value: "  \(Self.redcapShaped)\n",
            serviceType: "redcap"
        )

        #expect(decision.isAdmitted)
        #expect(decision.normalizedValue == Self.redcapShaped)
    }

    // MARK: Whitespace — trimming a password is a bug, trimming a token is not

    /// A password may legitimately begin or end with a space. With no declared
    /// format and no recognisable issuer, ASTRA does not know what it is
    /// holding, and trimming turns a correct paste into an authentication
    /// failure the user cannot see or explain.
    @Test("Surrounding spaces survive where nothing declares the value's shape")
    func passwordSpacesAreStored() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "DB_PASSWORD",
            value: " correct horse battery staple ",
            serviceType: "postgres"
        )

        #expect(decision.isAdmitted)
        #expect(decision.normalizedValue == " correct horse battery staple ")
    }

    /// Nothing issues a credential containing a line break, and a trailing
    /// newline off a `cat` or a copied code block is the commonest way a valid
    /// secret gets stored broken.
    @Test("Line breaks and tabs go even where spaces stay")
    func lineBreaksAreAlwaysRemoved() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "DB_PASSWORD",
            value: " pass\tword\nbroken\r\nacross lines\n",
            serviceType: "postgres"
        )

        #expect(decision.isAdmitted)
        #expect(decision.normalizedValue == " passwordbrokenacross lines")
    }

    /// The storable form is looser than it was; the rules must not be. Judging
    /// them on the canonical form is what stops a leading space smuggling a
    /// foreign token past the vendor fingerprint.
    @Test("A leading space does not hide a foreign vendor's token")
    func leadingSpaceDoesNotDefeatTheVendorRule() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN",
            value: "  \(Self.atlassianShaped)",
            serviceType: "redcap"
        )

        #expect(decision.verdict.auditReason == "foreign_vendor")
    }

    @Test("A value made only of spaces is still refused as empty")
    func allSpacesIsEmpty() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "DB_PASSWORD",
            value: "     ",
            serviceType: "postgres"
        )

        #expect(decision.verdict.auditReason == "empty")
    }

    // MARK: Format

    @Test("A REDCap token of the wrong shape is refused with the expected shape")
    func redcapTokenOfWrongShapeRefused() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN",
            value: "not-hex-and-far-too-short",
            serviceType: "redcap"
        )

        guard case .formatMismatch(let expectation, _) = decision.verdict else {
            Issue.record("Expected a format mismatch, got \(decision.verdict)")
            return
        }
        #expect(expectation.contains("32-character hexadecimal"))
    }

    @Test("A package-declared format overrides the built-in registry")
    func declaredFormatOverridesRegistry() {
        let format = ConnectorCredentialFormat(
            pattern: "acme_[0-9]{6}",
            expectation: "an Acme six-digit key"
        )
        let admitted = ConnectorCredentialAdmission.evaluate(
            key: "ACME_KEY", value: "acme_123456", serviceType: "acme", declaredFormat: format)
        let refused = ConnectorCredentialAdmission.evaluate(
            key: "ACME_KEY", value: "acme_12", serviceType: "acme", declaredFormat: format)

        #expect(admitted.isAdmitted)
        #expect(!refused.isAdmitted)
    }

    @Test("A format anchors, so a value that merely contains a match is refused")
    func formatIsAnchored() {
        let format = ConnectorCredentialFormat(pattern: "[0-9]{4}", expectation: "four digits")

        #expect(format.admits("1234"))
        #expect(!format.admits("pin=1234;"))
    }

    @Test("An uncompilable pattern fails open rather than locking the user out")
    func brokenPatternFailsOpen() {
        let format = ConnectorCredentialFormat(pattern: "([unclosed", expectation: "anything")

        #expect(format.admits("whatever-the-user-pasted"))
    }

    // MARK: Placeholders

    @Test("Template placeholders are refused", arguments: [
        "changeme", "TOKEN", "your-token-here", "<your-token>", "{{REDCAP_TOKEN}}",
        "${REDCAP_TOKEN}", "xxxxxxxx", "TODO"
    ])
    func placeholdersRefused(value: String) {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "API_TOKEN", value: value, serviceType: "custom")

        #expect(decision.verdict == .placeholder, "\(value) should read as a placeholder")
    }

    @Test("An empty value is refused as empty, not as a placeholder")
    func emptyValueRefusedAsEmpty() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "API_TOKEN", value: "   ", serviceType: "custom")

        #expect(decision.verdict == .empty)
    }

    // MARK: False positives — the cost of over-blocking is a user who cannot work

    @Test("A vendor token is admitted for its own service", arguments: [
        ("jira", "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000"),
        ("confluence", "ATCTT3xFfGF0aaaabbbbccccddddeeeeffff0000"),
        ("github", "ghp_aaaabbbbccccddddeeeeffff0000111122"),
        ("slack", "xoxb-1111111111-2222222222-abcdefghijkl"),
        ("google_cloud", "ya29.aQd3fF1kNotARealTokenJustShaped"),
        ("anthropic", "sk-ant-api03-aaaabbbbccccddddeeeeffff")
    ])
    func vendorTokenAdmittedForItsOwnService(pair: (service: String, value: String)) {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "API_TOKEN", value: pair.value, serviceType: pair.service)

        #expect(decision.isAdmitted, "\(pair.service) should accept its own vendor's token")
    }

    @Test("An unfamiliar credential for an unfamiliar service is admitted")
    func unknownVendorForUnknownServiceAdmitted() {
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "API_TOKEN",
            value: "Zt9-kQ4mR7wL2xP8nB5vC1jH6dF3sA0y",
            serviceType: "some_internal_service")

        #expect(decision.isAdmitted)
    }

    @Test("A generic connector may hold any vendor's token")
    func vendorAgnosticServiceAcceptsAnyVendor() {
        for service in ["custom", "rest_api", "http", "generic", "webhook", ""] {
            let decision = ConnectorCredentialAdmission.evaluate(
                key: "API_TOKEN", value: Self.atlassianShaped, serviceType: service)
            #expect(decision.isAdmitted, "\(service) is a passthrough connector and must stay usable")
        }
    }

    @Test("A short prefix that is not diagnostic does not fingerprint a vendor")
    func nonDiagnosticPrefixesAreNotVendors() {
        // A bare `sk-` is used by many providers; claiming it is OpenAI's would
        // block valid credentials on unrelated services.
        #expect(ConnectorCredentialFormatRegistry.vendor(of: "sk-aaaabbbbccccddddeeee") == nil)
    }

    @Test("Longest prefix wins so a specific vendor is not shadowed")
    func longestVendorPrefixWins() {
        let vendor = ConnectorCredentialFormatRegistry.vendor(of: "sk-ant-api03-aaaabbbbccccdddd")

        #expect(vendor?.name == "Anthropic")
    }

    // MARK: Cross-service reuse

    @Test("The same secret on two different services is refused")
    func crossServiceReuseRefused() {
        let site = ConnectorCredentialReuseSite(
            connectorID: UUID(),
            connectorName: "Jira",
            serviceType: "jira",
            credentialKey: "JIRA_API_TOKEN")
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "SERVICENOW_TOKEN",
            value: "Zt9-kQ4mR7wL2xP8nB5vC1jH6dF3sA0y",
            serviceType: "servicenow",
            reuseSites: [site])

        guard case .reusedAcrossServices(let ownerName, let ownerServiceType, let key) = decision.verdict else {
            Issue.record("Expected a cross-service reuse verdict, got \(decision.verdict)")
            return
        }
        #expect(ownerName == "Jira")
        #expect(ownerServiceType == "jira")
        #expect(key == "JIRA_API_TOKEN")
    }

    @Test("The same secret shared between same-service connectors is allowed")
    func sameServiceReuseAllowed() {
        // Two rows fronting one Jira site legitimately share a token, and
        // ASTRA's stable keychain namespace is built on that assumption.
        let site = ConnectorCredentialReuseSite(
            connectorID: UUID(),
            connectorName: "Jira (team board)",
            serviceType: "jira",
            credentialKey: "JIRA_API_TOKEN")
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "JIRA_API_TOKEN",
            value: "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000",
            serviceType: "jira",
            reuseSites: [site])

        #expect(decision.isAdmitted)
    }

    // MARK: Ordering — the most actionable reason wins

    @Test("A foreign vendor is reported ahead of a format mismatch")
    func foreignVendorOutranksFormatMismatch() {
        // The Atlassian token also fails REDCap's 32-hex rule; naming the
        // issuer tells the user what actually went wrong.
        let decision = ConnectorCredentialAdmission.evaluate(
            key: "REDCAP_API_TOKEN", value: Self.atlassianShaped, serviceType: "redcap")

        #expect(decision.verdict.auditReason == "foreign_vendor")
    }

    // MARK: The registry the packaged capability declares

    @Test("The shipped REDCap package declares the token format")
    func shippedREDCapPackageDeclaresTokenFormat() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "redcap-workflow" })
        let connector = try #require(package.connectors.first { $0.serviceType == "redcap" })
        let hint = try #require(connector.credentialHints.first { $0.key == "REDCAP_API_TOKEN" })
        let format = try #require(hint.format)

        #expect(format.admits(Self.redcapShaped))
        #expect(!format.admits(Self.atlassianShaped))
    }
}

/// The lookup that lets a write made long after the install still see what the
/// installing package declared.
@Suite("Connector declared credential format")
struct ConnectorDeclaredCredentialFormatResolverTests {
    private static let atlassianShaped =
        "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000111122223333444455556666"
    private static let redcapShaped = "0123456789ABCDEF0123456789ABCDEF"

    /// The origin stamp the row already carries is enough; nothing has to be
    /// copied onto it, which is what keeps a package free to tighten its
    /// declaration in an update.
    @Test("A package's declaration is resolved from the origin stamp alone")
    func resolvesFromTheOriginStamp() throws {
        let format = try #require(ConnectorDeclaredCredentialFormatResolver.declaredFormat(
            originPackageID: "redcap-workflow",
            originComponentID: nil,
            // Lower-cased on purpose: hint keys are matched case-insensitively.
            key: "redcap_api_token"
        ))

        #expect(format.admits(Self.redcapShaped))
        #expect(!format.admits(Self.atlassianShaped))
    }

    @Test("An unknown package, or a key it never declared, resolves to nothing")
    func unknownOriginResolvesToNothing() {
        #expect(ConnectorDeclaredCredentialFormatResolver.declaredFormat(
            originPackageID: "no-such-package", originComponentID: nil, key: "REDCAP_API_TOKEN") == nil)
        #expect(ConnectorDeclaredCredentialFormatResolver.declaredFormat(
            originPackageID: "redcap-workflow", originComponentID: nil, key: "SOME_OTHER_KEY") == nil)
    }

    /// `originComponentID` encodes the connector's name, so a rename in a
    /// package update orphans the stamp. Falling back to the package's other
    /// connectors cannot make the check wrong — it can only find a declaration
    /// the same package made for the same key — and losing it would silently
    /// reopen the hole.
    @Test("A stale component stamp falls back to the package's own connectors")
    func staleComponentStampFallsBack() {
        let format = ConnectorDeclaredCredentialFormatResolver.declaredFormat(
            originPackageID: "redcap-workflow",
            originComponentID: "connector:renamed-away",
            key: "REDCAP_API_TOKEN"
        )

        #expect(format?.admits(Self.redcapShaped) == true)
    }

    /// Unregistered, the seam answers `nil` instead of trapping. Credential
    /// writes run on paths that start long before `registerAll()` in some tools,
    /// and the right behaviour without a resolver is the one that existed
    /// before it: fall back to the built-in registry.
    @Test("The seam answers for a connector with no origin without trapping")
    func seamIsOptionalNotFailFast() {
        #expect(ConnectorDeclaredCredentialFormatSeam.declaredFormat(
            originPackageID: nil, originComponentID: nil, key: "REDCAP_API_TOKEN") == nil)
        #expect(ConnectorDeclaredCredentialFormatSeam.declaredFormat(
            originPackageID: "", originComponentID: nil, key: "REDCAP_API_TOKEN") == nil)
    }
}

/// Admission is enforced at the `Connector` write itself, so no entry point
/// can route around it.
@Suite("Connector Credential Admission Enforcement")
struct ConnectorCredentialAdmissionEnforcementTests {
    private static let atlassianShaped =
        "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000111122223333444455556666"
    private static let redcapShaped = "0123456789ABCDEF0123456789ABCDEF"

    /// Holds the container: `ModelContext` does not keep its container alive,
    /// and SwiftData traps the moment the container is released underneath it.
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }
    }

    @MainActor
    private static func makeFixture() throws -> Fixture {
        Fixture(container: try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    @MainActor
    @Test("saveCredentialChecked refuses a foreign vendor's token and writes nothing")
    func saveRefusesForeignVendorToken() throws {
        let fixture = try Self.makeFixture()
        let context = fixture.context
        let store = MockSecretStore()
        let connector = Connector(
            name: "REDCap", serviceType: "redcap", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")
        context.insert(connector)

        let outcome = connector.saveCredentialChecked(
            key: "REDCAP_API_TOKEN", value: Self.atlassianShaped, store: store)

        #expect(outcome.rejection?.auditReason == "foreign_vendor")
        #expect(!connector.credentialKeys.contains("REDCAP_API_TOKEN"))
        for entityID in KeychainSecretStore.connectorEntityIDs(for: connector) {
            #expect(store.load(key: "REDCAP_API_TOKEN", entityID: entityID) == nil)
        }
    }

    @MainActor
    @Test("saveCredentialChecked stores a valid token")
    func saveStoresValidToken() throws {
        let fixture = try Self.makeFixture()
        let context = fixture.context
        let store = MockSecretStore()
        let connector = Connector(
            name: "REDCap", serviceType: "redcap", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")
        context.insert(connector)

        let outcome = connector.saveCredentialChecked(
            key: "REDCAP_API_TOKEN", value: Self.redcapShaped, store: store)

        #expect(outcome == .saved)
        #expect(connector.credentialKeys.contains("REDCAP_API_TOKEN"))
        #expect(connector.credentials(store: store)["REDCAP_API_TOKEN"] == Self.redcapShaped)
    }

    @MainActor
    @Test("A secret already held by another service is refused at the write")
    func saveRefusesCrossServiceReuseAgainstTheStore() throws {
        let fixture = try Self.makeFixture()
        let context = fixture.context
        let store = MockSecretStore()
        let jira = Connector(
            name: "Jira", serviceType: "jira", icon: "list.bullet.rectangle",
            baseURL: "https://example.atlassian.net", authMethod: "basic")
        context.insert(jira)
        #expect(jira.saveCredentialChecked(
            key: "JIRA_API_TOKEN", value: Self.atlassianShaped, store: store) == .saved)

        // A generic connector would otherwise happily accept the Atlassian
        // token: the vendor rule alone does not cover it.
        let other = Connector(
            name: "Internal API", serviceType: "rest_api", icon: "arrow.left.arrow.right",
            baseURL: "https://internal.example.edu", authMethod: "bearer")
        context.insert(other)

        let outcome = other.saveCredentialChecked(
            key: "API_TOKEN", value: Self.atlassianShaped, store: store)

        #expect(outcome.rejection?.auditReason == "reused_across_services")
        #expect(!other.credentialKeys.contains("API_TOKEN"))
    }

    @MainActor
    @Test("Two connectors for the same service may hold the same secret")
    func saveAllowsSameServiceSharing() throws {
        let fixture = try Self.makeFixture()
        let context = fixture.context
        let store = MockSecretStore()
        let board = Connector(
            name: "Jira (board)", serviceType: "jira", icon: "list.bullet.rectangle",
            baseURL: "https://example.atlassian.net", authMethod: "basic")
        context.insert(board)
        #expect(board.saveCredentialChecked(
            key: "JIRA_API_TOKEN", value: Self.atlassianShaped, store: store) == .saved)

        let backlog = Connector(
            name: "Jira (backlog)", serviceType: "jira", icon: "list.bullet.rectangle",
            baseURL: "https://example.atlassian.net", authMethod: "basic")
        context.insert(backlog)

        let outcome = backlog.saveCredentialChecked(
            key: "JIRA_API_TOKEN", value: Self.atlassianShaped, store: store)

        #expect(outcome == .saved)
    }

    @MainActor
    @Test("A detached connector still gets the pure rules")
    func detachedConnectorStillChecked() {
        // No ModelContext means no reuse scan, but the vendor and format rules
        // are pure and must still apply — the install path saves before the
        // row is inserted.
        let store = MockSecretStore()
        let connector = Connector(
            name: "REDCap", serviceType: "redcap", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")

        let outcome = connector.saveCredentialChecked(
            key: "REDCAP_API_TOKEN", value: Self.atlassianShaped, store: store)

        #expect(outcome.rejection?.auditReason == "foreign_vendor")
    }

    /// `CapabilityInstaller` was the only caller that passed `declaredFormat`,
    /// so it covered exactly one write. Every later write — a rotated token
    /// replaced in Configure › Connectors, a repair, a copied setup — asked with
    /// `nil`, and for a service with no built-in registry entry that meant no
    /// format check at all: the package could declare a shape and ASTRA would
    /// still store whatever was pasted.
    @MainActor
    @Test("A later write is checked against the format the package declared")
    func laterWriteHonoursThePackageDeclaration() throws {
        let fixture = try Self.makeFixture()
        let store = MockSecretStore()
        // `rest_api` has no entry in the built-in registry, so the package's
        // declaration is the only thing that can refuse this.
        #expect(ConnectorCredentialFormatRegistry.format(
            serviceType: "rest_api", key: "REDCAP_API_TOKEN") == nil)
        let connector = Connector(
            name: "REDCap (copied setup)", serviceType: "rest_api", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")
        connector.originPackageID = "redcap-workflow"
        fixture.context.insert(connector)

        let refused = connector.saveCredentialChecked(
            key: "REDCAP_API_TOKEN", value: "pasted-the-wrong-thing-again", store: store)
        #expect(refused.rejection?.auditReason == "format_mismatch")
        #expect(!connector.credentialKeys.contains("REDCAP_API_TOKEN"))

        // And it is a check, not a blockade: the shape the package declared
        // still goes in.
        #expect(connector.saveCredentialChecked(
            key: "REDCAP_API_TOKEN", value: Self.redcapShaped, store: store) == .saved)
    }

    /// A connector nobody installed has no origin to look up, and must not
    /// inherit a stranger's rules.
    @MainActor
    @Test("A hand-made connector is unaffected by any package's declaration")
    func handMadeConnectorHasNoDeclaredFormat() throws {
        let fixture = try Self.makeFixture()
        let store = MockSecretStore()
        let connector = Connector(
            name: "Internal API", serviceType: "rest_api", icon: "arrow.left.arrow.right",
            baseURL: "https://internal.example.edu", authMethod: "bearer")
        fixture.context.insert(connector)

        #expect(connector.originPackageID == nil)
        #expect(connector.saveCredentialChecked(
            key: "REDCAP_API_TOKEN", value: "pasted-the-wrong-thing-again", store: store) == .saved)
    }

    @MainActor
    @Test("A truncated reuse scan reports itself instead of reading as clean")
    func reuseScanReportsTruncation() throws {
        let fixture = try Self.makeFixture()
        let context = fixture.context
        let store = MockSecretStore()
        let subject = Connector(
            name: "Subject", serviceType: "redcap", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")
        context.insert(subject)

        let overLimit = ConnectorSecurityPolicy.credentialReuseScanLimit + 5
        for index in 0..<overLimit {
            let other = Connector(
                name: "Other \(index)", serviceType: "service_\(index)", icon: "bolt",
                baseURL: "https://example.test/\(index)", authMethod: "bearer")
            context.insert(other)
            other.credentialKeys = ["API_TOKEN"]
            other.credentialValues = [""]
        }

        let scan = ConnectorSecurityPolicy.credentialReuseScan(
            for: Self.redcapShaped, excluding: subject, in: context, store: store)

        #expect(scan.wasTruncated)
        #expect(scan.scannedConnectorCount == ConnectorSecurityPolicy.credentialReuseScanLimit)
    }
}
