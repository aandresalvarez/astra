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
    /// Save" sends them looking for a dialog that will never appear. Nor is a
    /// rebuild the remedy: see `ConnectorCredentialRetryWriteTests`.
    @Test("A missing bootstrap item is not presented as a denied prompt")
    func missingKeychainItemIsNotPresentedAsADeniedPrompt() {
        let presentation = ConnectorCredentialSaveFailurePresentation.keychainSaveFailed(
            key: "JIRA_EMAIL",
            diagnosis: .notConfigured
        )

        #expect(presentation.message.contains("JIRA_EMAIL"))
        #expect(presentation.actionTitle == "Not saved")
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
        #expect(missingItem.actionTitle == "Not saved")
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

/// The button promised a repair the layer below refuses to perform.
///
/// `.notConfigured` is `errSecItemNotFound` raised at the `bootstrap-password`
/// stage, and that stage asks for the password without creating one only when
/// the keychain file already exists — so the diagnosis means "the store is on
/// disk and the item that unlocks it is gone". A rebuild sounds like the
/// remedy, and it is not available: recovery is fenced by
/// `dedicatedKeychainIsBeyondRecoveryAtPath:`, which admits only a file that is
/// missing or unparseable. An orphaned-but-intact keychain opens fine and
/// reports a healthy status, so the fence holds it back and `writeSecret`
/// returns without recovering — whichever variant is called.
///
/// Both halves have to be checked, and checking only one is how the wrong fix
/// got written: that the fence never *misfires* on a healthy keychain is a
/// different question from whether it ever *fires* for this diagnosis. It does
/// not. So there is no button.
@Suite("Credential retry never offers a write that cannot succeed")
struct ConnectorCredentialRetryWriteTests {

    @Test("A missing bootstrap item offers no retry at all")
    func missingBootstrapItemOffersNoRetry() {
        let presentation = ConnectorCredentialSaveFailurePresentation.keychainSaveFailed(
            key: "JIRA_EMAIL",
            diagnosis: .notConfigured
        )

        #expect(presentation.isRetryable == false)
        // The message has to say the credentials are gone. Anything softer
        // reads as "try again later", which is the state this replaced.
        #expect(presentation.message.contains("cannot be recovered"))
        #expect(presentation.message.contains("will not help"))
    }

    /// The inverse must not drift. A refused ACL is cleared by securityd's
    /// dialog and by nothing else, so this case keeps its button.
    @Test("A refused ACL is still retryable")
    func deniedAccessStaysRetryable() {
        for diagnosis: KeychainWriteDiagnosis? in [.accessDenied, .unknown, nil] {
            let presentation = ConnectorCredentialSaveFailurePresentation.keychainSaveFailed(
                key: "JIRA_EMAIL",
                diagnosis: diagnosis
            )
            #expect(presentation.isRetryable)
            #expect(presentation.actionTitle == "Allow & Save")
        }
    }

    @Test("An admission rejection offers no write at all")
    func rejectionIsNotRetryable() {
        let presentation = ConnectorCredentialSaveFailurePresentation.forFailedSave(
            .rejected(.formatMismatch(expectation: "an email address", observedShape: "opaque token")),
            key: "JIRA_EMAIL"
        )

        #expect(presentation.isRetryable == false)
    }

    /// The assertion that would have caught the wrong fix, stated against the
    /// layer that decides it rather than against the UI that guessed.
    /// `keychainStatusIsBeyondRecovery:` is the entire gate, and `.notConfigured`
    /// carries `errSecItemNotFound` — if that code is ever added here a rebuild
    /// becomes reachable and the presentation above should be revisited, which
    /// is exactly when this should fail.
    @Test("The recovery gate cannot fire for a missing bootstrap item")
    func recoveryGateExcludesTheMissingItemStatus() throws {
        let gate = try objCMethodBody(
            startingWith: "+ (BOOL)keychainStatusIsBeyondRecovery:",
            endingBefore: "+ (BOOL)recoverUnreadableDedicatedKeychainAtPath:",
            in: try astraSecureKeychainSource()
        )

        #expect(gate.contains("errSecInvalidKeychain"))
        #expect(gate.contains("errSecNoSuchKeychain"))
        #expect(!gate.contains("errSecItemNotFound"))
    }

    /// With no rebuild to route to, the retry has one job: raise securityd's
    /// dialog. A non-interactive save here would silently remove the only
    /// remedy the button still has.
    @Test("The retry uses the interactive write")
    func retryUsesTheInteractiveWrite() throws {
        let source = try connectorsManagerViewSource()
        let retryBody = try viewMethodBody(
            startingWith: "private func retryPendingCredentialSave(",
            endingBefore: "private func addConfig(",
            in: source
        )

        #expect(retryBody.contains("addCredential()"))
        #expect(retryBody.contains("saveCredentialReplacement(for: key)"))

        for method in ["private func addCredential()", "private func saveCredentialReplacement(for key: String)"] {
            #expect(source.contains(method), "\(method) must not regrow an interaction parameter")
        }
    }
}

private func astraSecureKeychainSource() throws -> String {
    let testFile = URL(filePath: #filePath)
    let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = repoRoot.appending(path: "AstraObjCSupport/AstraSecureKeychain.m")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func objCMethodBody(startingWith start: String, endingBefore end: String, in source: String) throws -> String {
    let startRange = try #require(source.range(of: start))
    let remaining = source[startRange.lowerBound...]
    let endRange = try #require(remaining.range(of: end))
    return String(remaining[..<endRange.lowerBound])
}

private func connectorsManagerViewSource() throws -> String {
    let testFile = URL(filePath: #filePath)
    let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = repoRoot.appending(path: "Astra/Views/ConnectorsManagerView.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func viewMethodBody(startingWith start: String, endingBefore end: String, in source: String) throws -> String {
    let startRange = try #require(source.range(of: start))
    let remaining = source[startRange.lowerBound...]
    let endRange = try #require(remaining.range(of: end))
    return String(remaining[..<endRange.lowerBound])
}
