import Foundation

/// What the person in front of the app can actually do about a Keychain write
/// that did not land.
///
/// Lives here, in the module both ends can see, because the diagnosis has to
/// survive the trip back to the UI: `ASTRAPersistence` produces it (from
/// `AstraKeychainFailureReport`, whose `Diagnosis` is an alias for this) and
/// `ASTRAModels` carries it in `ConnectorCredentialSaveOutcome` — and
/// `ASTRAModels` cannot see `ASTRAPersistence`.
public enum KeychainWriteDiagnosis: Equatable, Sendable {
    /// The item exists and access was refused. Retrying interactively is the
    /// remedy: that is the attempt allowed to raise securityd's "allow access?"
    /// dialog.
    case accessDenied
    /// There is no bootstrap item to unlock the keychain with, so the message
    /// should not send the user to an access prompt that will never appear:
    /// there is no item for anyone to deny.
    ///
    /// Nor to a rebuild. This is `errSecItemNotFound` from the
    /// `bootstrap-password` stage, which asks without creating only when the
    /// keychain file already exists — so it means the store is on disk and its
    /// key is gone, and that pair is what `dedicatedKeychainIsBeyondRecoveryAtPath:`
    /// deliberately refuses to treat as recoverable: the file opens and reports
    /// a healthy status, which is indistinguishable from a keychain the user
    /// still needs. Both write variants therefore return without rebuilding.
    /// Nothing the UI can call resolves this, so the remedy is an explanation,
    /// not a button.
    case notConfigured
    /// Some other OSStatus. Reported as-is rather than guessed at.
    case unknown
}

/// A Keychain write and, when it failed, why.
///
/// The reason comes from a process-global slot that the Obj-C layer fills and
/// the first reader empties, so "the most recent failure" is only the right
/// answer for whoever asks first — and a second failing write, or any of the
/// batch drains on the startup and capability-install paths, can be that
/// reader. Returning the diagnosis alongside the write it belongs to is what
/// keeps a message on screen about *this* credential from being about some
/// other one.
public enum KeychainWriteOutcome: Equatable, Sendable {
    case written
    /// `diagnosis` is nil when the write failed and the layer had nothing to
    /// say about it — a blocked test-keychain access, or a failure whose report
    /// some other drain had already taken. Distinct from a diagnosis of
    /// `.unknown`, which means the layer did report a status and it was one
    /// this app cannot turn into advice.
    case failed(diagnosis: KeychainWriteDiagnosis?)

    public var didWrite: Bool { self == .written }

    public var diagnosis: KeychainWriteDiagnosis? {
        if case .failed(let diagnosis) = self { return diagnosis }
        return nil
    }
}
