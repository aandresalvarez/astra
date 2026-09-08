import Testing
import ASTRAPersistence
@testable import ASTRA

@Suite("Connector Credential Save Failure Presentation")
struct ConnectorCredentialSaveFailurePresentationTests {

    @Test("Keychain save failures expose a retry action")
    func keychainSaveFailureExposesRetryAction() {
        let presentation = ConnectorCredentialSaveFailurePresentation.keychainSaveFailed(key: "JIRA_EMAIL")

        #expect(presentation.message.contains("JIRA_EMAIL"))
        #expect(presentation.message.contains("Allow ASTRA"))
        #expect(presentation.actionTitle == "Allow & Save")
        #expect(presentation.actionSystemImage == MacOSPermissionKind.keychain.systemImage)
        #expect(!presentation.message.contains("Open Keychain Access"))
    }

    /// `errSecItemNotFound` means the bootstrap item is gone, not that access
    /// was refused — there is no ACL prompt for the user to allow, so "Allow &
    /// Save" sends them looking for a dialog that will never appear. A retry is
    /// the actual remedy: a write may rebuild the store, unlike a read.
    @Test("A missing bootstrap item is not presented as a denied prompt")
    func missingKeychainItemAsksForARetryInstead() {
        let presentation = ConnectorCredentialSaveFailurePresentation.keychainSaveFailed(
            key: "JIRA_EMAIL",
            diagnosis: .notConfigured
        )

        #expect(presentation.message.contains("JIRA_EMAIL"))
        #expect(presentation.actionTitle == "Retry")
        #expect(!presentation.message.contains("Allow ASTRA"))
    }

    /// The other diagnoses, and the absent one, must keep the access-prompt
    /// wording: a refused ACL is both the common case and the only one where
    /// retrying interactively can raise securityd's dialog.
    @Test("Denied access and an unknown status both keep the allow-and-retry path")
    func deniedAndUnknownKeepTheAccessPrompt() {
        for diagnosis: AstraKeychainFailureReport.Diagnosis? in [.accessDenied, .unknown, nil] {
            let presentation = ConnectorCredentialSaveFailurePresentation.keychainSaveFailed(
                key: "JIRA_EMAIL",
                diagnosis: diagnosis
            )
            #expect(presentation.actionTitle == "Allow & Save")
            #expect(presentation.message.contains("Allow ASTRA"))
        }
    }
}
