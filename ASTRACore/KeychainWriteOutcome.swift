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
    /// There is no bootstrap item to unlock the keychain with. Retrying a write
    /// can succeed on its own — a write is permitted to rebuild the store,
    /// unlike a read — so the message should not send the user to an access
    /// prompt that will never appear.
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
