import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The New Workspace wizard's Test Connection button sends the token the user
/// has just typed, and some endpoints quote the submitted parameters back in
/// their error body. `Connector.redcapAPIError` returns that body verbatim as
/// the failure detail, and the detail is written to the audit log — so a
/// provider that echoes wrote a second cleartext copy of the credential to
/// disk.
///
/// Nothing else covers these values. They are still draft: not in the Keychain,
/// not attached to a task, so `RunSecretRedactionScope` has never heard of them.
@Suite("Workspace capability validation redaction")
struct WorkspaceCapabilityValidationTelemetryTests {
    private static let redcapShaped = "0123456789ABCDEF0123456789ABCDEF"
    private static let atlassianShaped =
        "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000111122223333444455556666"

    @Test("A provider error that echoes the token is scrubbed before it is logged")
    func echoedTokenIsScrubbed() {
        let detail = """
        REDCap responded 400: {"error":"The value \(Self.redcapShaped) is not a valid token \
        for project 42"}
        """

        let redacted = WorkspaceCapabilityValidationTelemetry.redacted(
            detail,
            credentials: ["REDCAP_API_TOKEN": Self.redcapShaped]
        )

        #expect(!redacted.contains(Self.redcapShaped))
        // Scrubbed, not dropped. The detail is the reason this event records
        // anything at all: it exists because a reported failure left no line in
        // the log, and a redacted message still names the host and the reason.
        #expect(redacted.contains("REDCap responded 400"))
        #expect(redacted.contains("project 42"))
    }

    @Test("Every draft credential is scrubbed, not just the first")
    func everyDraftCredentialIsScrubbed() {
        let detail = "auth failed for user@example.com with \(Self.atlassianShaped)"

        let redacted = WorkspaceCapabilityValidationTelemetry.redacted(
            detail,
            credentials: [
                "JIRA_EMAIL": "user@example.com",
                "JIRA_API_TOKEN": Self.atlassianShaped
            ]
        )

        #expect(!redacted.contains(Self.atlassianShaped))
        #expect(!redacted.contains("user@example.com"))
    }

    /// Short values are left alone on purpose: redacting a three-character
    /// string shreds the message without protecting anything.
    @Test("A value too short to be a secret does not shred the message")
    func shortValuesAreLeftAlone() {
        let detail = "project ab is not visible to this account"

        let redacted = WorkspaceCapabilityValidationTelemetry.redacted(
            detail,
            credentials: ["REDCAP_API_TOKEN": "ab"]
        )

        #expect(redacted == detail)
    }

    /// The scrub list and the list the test actually submits have to be one
    /// list, or the next connector added grows a gap whose symptom is a token
    /// in the log rather than a compile error.
    @Test("The scrubbed credentials are the credentials the test submits")
    func scrubbedCredentialsMatchTheSubmittedOnes() {
        var configuration = OnboardingCapabilityConfiguration()
        configuration.jiraEmail = "user@example.com"
        configuration.jiraAPIToken = Self.atlassianShaped
        configuration.redcapAPIToken = Self.redcapShaped

        let jira = WorkspaceCapabilityConnectorValidation.draftCredentials(
            packageID: OnboardingCapabilitySetup.jiraPackageID,
            configuration: configuration
        )
        #expect(jira["JIRA_EMAIL"] == "user@example.com")
        #expect(jira["JIRA_API_TOKEN"] == Self.atlassianShaped)

        let redcap = WorkspaceCapabilityConnectorValidation.draftCredentials(
            packageID: OnboardingCapabilitySetup.redcapPackageID,
            configuration: configuration
        )
        #expect(redcap == ["REDCAP_API_TOKEN": Self.redcapShaped])

        // A package whose test spends a subprocess rather than a credential
        // sends nothing the user typed, so there is nothing to scrub.
        #expect(WorkspaceCapabilityConnectorValidation.draftCredentials(
            packageID: "github-workflow", configuration: configuration).isEmpty)
    }
}
