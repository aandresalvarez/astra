import Testing
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
}
