import Foundation
import Testing
import ASTRACore
import ASTRAModels
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

/// The diagnosis behind a failed credential write used to be fetched from
/// `AstraSecureKeychainStore.latestFailure` — one process-global slot, filled by
/// a drain that empties it. Between the write and the sheet that explains it,
/// any other failing write, or any of the batch drains on the startup,
/// workspace-setup and capability-install paths, could replace or empty that
/// slot. The user was then told to grant Keychain access for a keychain that was
/// merely unconfigured, or sent to retry when access had actually been refused.
/// The diagnosis now travels with the outcome.
@Suite("Connector credential save outcome carries its own diagnosis")
struct ConnectorCredentialSaveOutcomeDiagnosisTests {

    @Test("A keychain failure presents the diagnosis the write returned")
    func presentationFollowsTheOutcome() {
        let missingItem = ConnectorCredentialSaveFailurePresentation.forFailedSave(
            .keychainWriteFailed(diagnosis: .notConfigured),
            key: "JIRA_EMAIL"
        )
        #expect(missingItem.actionTitle == "Retry")
        #expect(!missingItem.message.contains("Allow ASTRA"))

        let refused = ConnectorCredentialSaveFailurePresentation.forFailedSave(
            .keychainWriteFailed(diagnosis: .accessDenied),
            key: "JIRA_EMAIL"
        )
        #expect(refused.actionTitle == "Allow & Save")
        #expect(refused.message.contains("Allow ASTRA"))
    }

    /// No diagnosis is still the access-prompt default — the common case, and
    /// the only one where retrying interactively can raise securityd's dialog.
    @Test("An outcome with no diagnosis keeps the access-prompt default")
    func absentDiagnosisKeepsTheDefault() {
        let presentation = ConnectorCredentialSaveFailurePresentation.forFailedSave(
            .keychainWriteFailed(diagnosis: nil),
            key: "JIRA_EMAIL"
        )

        #expect(presentation.actionTitle == "Allow & Save")
        #expect(presentation.isRetryable)
    }

    /// An admission rejection never reached the Keychain at all, so it must not
    /// pick up a Keychain remedy on the way out.
    @Test("An admission rejection is presented as a rejection")
    func rejectionIsNotAKeychainFailure() {
        let outcome = ConnectorCredentialSaveOutcome.rejected(
            .formatMismatch(expectation: "an email address", observedShape: "opaque token")
        )
        let presentation = ConnectorCredentialSaveFailurePresentation.forFailedSave(
            outcome,
            key: "JIRA_EMAIL"
        )

        #expect(presentation.isRetryable == false)
        #expect(outcome.keychainDiagnosis == nil)
    }

    @Test("Only a failed write carries a diagnosis")
    func savedOutcomeHasNoDiagnosis() {
        #expect(ConnectorCredentialSaveOutcome.saved.keychainDiagnosis == nil)
        #expect(ConnectorCredentialSaveOutcome.saved.isSaved)
        #expect(ConnectorCredentialSaveOutcome.keychainWriteFailed(diagnosis: .unknown).isSaved == false)
        #expect(
            ConnectorCredentialSaveOutcome.keychainWriteFailed(diagnosis: .unknown).keychainDiagnosis == .unknown
        )
    }
}

/// A conformer with no Keychain under it — the shape every test fake has. The
/// diagnosis-carrying write is a protocol-extension default precisely so these
/// keep compiling and keep behaving as they did.
private enum StubConnectorSecretPersistence: ConnectorSecretPersisting {
    nonisolated(unsafe) static var writeSucceeds = true

    static func loadAllCredentials(keys: [String], facts: ConnectorSecretFacts, store: SecretStore) -> [String: String] { [:] }
    static func saveCredential(_ value: String, key: String, facts: ConnectorSecretFacts, allowUserInteraction: Bool) -> Bool { writeSucceeds }
    static func saveCredential(_ value: String, key: String, facts: ConnectorSecretFacts, store: SecretStore) -> Bool { writeSucceeds }
    static func deleteCredential(key: String, facts: ConnectorSecretFacts) -> Bool { true }
    static func credentialExists(key: String, facts: ConnectorSecretFacts) -> Bool { false }
    static func loadCredential(key: String, facts: ConnectorSecretFacts) -> String? { nil }
    static func deleteAllCredentials(facts: ConnectorSecretFacts) {}
    static func synchronizeCredentialNamespaces(keys: [String], facts: ConnectorSecretFacts) {}
}

@Suite("Keychain write outcome")
struct KeychainWriteOutcomeTests {

    @Test("A conformer without the diagnosis-carrying write still reports success and failure")
    func defaultImplementationMirrorsTheBoolWrite() {
        let facts = ConnectorSecretFacts(
            id: UUID(),
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net",
            originPackageID: nil,
            originComponentID: nil
        )

        StubConnectorSecretPersistence.writeSucceeds = true
        #expect(StubConnectorSecretPersistence.saveCredentialReportingFailure(
            "v", key: "K", facts: facts, allowUserInteraction: false
        ) == .written)

        StubConnectorSecretPersistence.writeSucceeds = false
        let failed = StubConnectorSecretPersistence.saveCredentialReportingFailure(
            "v", key: "K", facts: facts, allowUserInteraction: false
        )
        #expect(failed == .failed(diagnosis: nil))
        #expect(failed.didWrite == false)
        // Nil is "the layer had nothing to say", which is not the same claim as
        // a diagnosis of `.unknown` ("it reported a status I cannot advise on").
        #expect(failed.diagnosis == nil)
    }

    @Test("Only a written outcome reads as written")
    func writtenIsTheOnlySuccess() {
        #expect(KeychainWriteOutcome.written.didWrite)
        #expect(KeychainWriteOutcome.written.diagnosis == nil)
        for diagnosis: KeychainWriteDiagnosis? in [.accessDenied, .notConfigured, .unknown, nil] {
            let outcome = KeychainWriteOutcome.failed(diagnosis: diagnosis)
            #expect(outcome.didWrite == false)
            #expect(outcome.diagnosis == diagnosis)
        }
    }
}
