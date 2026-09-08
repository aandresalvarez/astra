import Foundation
import Security
import AstraObjCSupport
import ASTRACore

/// The structured form of the `keychain.unavailable` log line.
///
/// The Obj-C layer already distinguishes the two ways the dedicated keychain
/// becomes unopenable, and the distinction decides what the user should do:
/// `errSecItemNotFound` means the bootstrap item is gone, `errSecAuthFailed` /
/// `errSecInteractionNotAllowed` mean it is there and this binary was refused
/// it by the ACL partition list. Until now that difference reached exactly one
/// place — a warning line in the log — while the UI said "Allow ASTRA to access
/// its Keychain item, then retry" for both. Production ran 17 days of
/// `status=-25293` behind 13 silent credential-save failures with nothing on
/// screen naming the keychain at all.
public struct AstraKeychainFailureReport: Equatable, Sendable {
    /// What the person in front of the app can actually do about it.
    public enum Diagnosis: Equatable, Sendable {
        /// The item exists and access was refused. Retrying interactively is
        /// the remedy: that is the attempt allowed to raise securityd's
        /// "allow access?" dialog.
        case accessDenied
        /// There is no bootstrap item to unlock the keychain with. Retrying a
        /// write can succeed on its own — a write is permitted to rebuild the
        /// store, unlike a read — so the message should not send the user to
        /// an access prompt that will never appear.
        case notConfigured
        /// Some other OSStatus. Reported as-is rather than guessed at.
        case unknown
    }

    /// Which step failed, e.g. `bootstrap-password`. A fixed set of identifiers
    /// from the Obj-C layer; never a path, account, or secret.
    public let stage: String
    public let status: OSStatus
    /// Failures folded into this report since the last drain. Large counts are
    /// the signature of a degraded keychain being retried per credential.
    public let suppressedCount: Int

    public var diagnosis: Diagnosis {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed: return .accessDenied
        case errSecItemNotFound: return .notConfigured
        default: return .unknown
        }
    }

    /// Parses `stage=… status=… suppressed=…` as emitted by
    /// `AstraSecureKeychain.takeLastKeychainFailureReport`. Returns `nil` for
    /// anything that does not carry a stage and a status, so a format change in
    /// the Obj-C layer degrades to "no diagnosis" rather than to a wrong one.
    public init?(rawReport: String) {
        var parsed: [String: String] = [:]
        for component in rawReport.split(separator: " ") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            parsed[String(pair[0])] = String(pair[1])
        }
        guard let stage = parsed["stage"], !stage.isEmpty,
              let rawStatus = parsed["status"], let status = Int32(rawStatus)
        else { return nil }
        self.stage = stage
        self.status = status
        suppressedCount = parsed["suppressed"].flatMap(Int.init) ?? 0
    }
}

/// Single internal chokepoint for storing ASTRA's *own* secrets (connector and
/// skill credentials). Routes them into a dedicated keychain file — separate
/// from the user's `login.keychain-db` — so they are never inside the encrypted
/// login-keychain blob the sandboxed Copilot/agent process is granted read
/// access to (which only needs the gh GitHub token).
///
/// `KeychainService` and `KeychainSecretStore` both delegate here, so the
/// storage location is defined in exactly one place. The low-level keychain work
/// (and the deliberate use of the deprecated file-keychain API) lives in
/// `AstraSecureKeychain` (Obj-C); this layer only supplies the channel-derived
/// keychain path + bootstrap service.
///
/// All operations fail closed: if the dedicated keychain cannot be created /
/// opened / unlocked, writes return `false` and reads return `nil` rather than
/// silently falling back to `login.keychain-db`.
public enum AstraSecureKeychainStore {

    /// Test-only redirect of the dedicated keychain file path. Task-local so a
    /// test can point the store at a throwaway keychain without touching the real
    /// per-channel file and without leaking the override to concurrently-running
    /// tests. `nil` in production → the channel's real keychain path.
    @TaskLocal static var keychainPathOverride: String?

    /// Test-only redirect of the login-keychain bootstrap service (paired with
    /// `keychainPathOverride`). `nil` in production.
    @TaskLocal static var bootstrapServiceOverride: String?

    // The three values below are fixed for the lifetime of the process — they
    // derive from the bundle's Info.plist, the environment, and the home
    // directory — but they used to be recomputed on every single call. Each
    // rebuilt `AppChannel.current` (an Info.plist lookup plus a full
    // `ProcessInfo.environment` dictionary), and `isRunningTests` built that
    // dictionary a second time. That is pure Swift overhead paid per credential
    // lookup, and the callers above this layer issue them in the hundreds:
    // `CapabilitySetupCopier.copySetup` alone is over a hundred loads.
    private static let channelKeychainPath = AppChannel.current.astraKeychainPath
    private static let channelBootstrapService = AppChannel.current.astraKeychainBootstrapService

    private static var keychainPath: String {
        keychainPathOverride ?? channelKeychainPath
    }

    private static var bootstrapService: String {
        bootstrapServiceOverride ?? channelBootstrapService
    }

    static var isUsingExplicitTestKeychain: Bool {
        keychainPathOverride != nil && bootstrapServiceOverride != nil
    }

    static var shouldBlockUnscopedTestKeychainAccess: Bool {
        isRunningTests && !isUsingExplicitTestKeychain
    }

    private static let isRunningTests: Bool = {
        // SwiftPM's test helper is ad-hoc signed separately from ASTRA.app. If
        // it creates the real per-channel keychain/bootstrap item, ASTRA cannot
        // reliably read that item later. Tests that exercise Keychain behavior
        // must use the task-local temp keychain overrides above.
        let processName = ProcessInfo.processInfo.processName
        return processName == "swiftpm-testing-helper"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    // MARK: - CRUD

    @discardableResult
    public static func save(
        service: String,
        account: String,
        value: String,
        label: String?,
        allowUserInteraction: Bool = false
    ) -> Bool {
        guard !shouldBlockUnscopedTestKeychainAccess else { return false }
        let saved: Bool
        if allowUserInteraction {
            saved = AstraSecureKeychain.saveSecretAllowingUserInteraction(
                value,
                forAccount: account,
                service: service,
                label: label,
                keychainPath: keychainPath,
                bootstrapService: bootstrapService
            )
        } else {
            saved = AstraSecureKeychain.saveSecret(
                value,
                forAccount: account,
                service: service,
                label: label,
                keychainPath: keychainPath,
                bootstrapService: bootstrapService
            )
        }
        if !saved {
            // Drain here, at the one chokepoint every write passes through,
            // rather than at each caller — a new writer then cannot be silent by
            // omission. Before this the only drains were on the startup,
            // workspace_setup and capability_install paths, so eleven
            // consecutive connector failures on 2026-08-17 logged
            // `keychain.save_failed scope=connector` eleven times and not one
            // `keychain.unavailable`; the -25293 behind them had to be
            // recovered from securityd's own log. A failed write is the one
            // moment the app knows something is wrong *and* knows a human is
            // waiting on it.
            //
            // Accepted cost: `suppressed=` stops being additive across scopes,
            // since this competes with the other drains for one process-global
            // counter. Attributing a failure when it happens is worth more than
            // a hoarded count.
            logPendingKeychainFailure(scope: "keychain_write")
        }
        return saved
    }

    public static func load(service: String, account: String) -> String? {
        guard !shouldBlockUnscopedTestKeychainAccess else { return nil }
        return AstraSecureKeychain.secret(
            forAccount: account,
            service: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        guard !shouldBlockUnscopedTestKeychainAccess else { return false }
        return AstraSecureKeychain.deleteSecret(
            forAccount: account,
            service: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    @discardableResult
    public static func deleteAll(service: String) -> Bool {
        guard !shouldBlockUnscopedTestKeychainAccess else { return false }
        return AstraSecureKeychain.deleteAllSecrets(
            forService: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    public static func exists(service: String, account: String) -> Bool {
        guard !shouldBlockUnscopedTestKeychainAccess else { return false }
        return AstraSecureKeychain.hasSecret(
            forAccount: account,
            service: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    // MARK: - Migration & diagnostics

    /// One-time, idempotent move of any legacy items for `service` from the login
    /// keychain into the dedicated keychain. Returns the number of items moved
    /// (`0` when there was nothing to migrate, `-1` on a hard failure). Driven
    /// per-entity from the existing launch migration hooks.
    @discardableResult
    public static func migrateServiceFromLoginKeychain(service: String) -> Int {
        guard !shouldBlockUnscopedTestKeychainAccess else { return -1 }
        return AstraSecureKeychain.migrateService(
            fromLoginKeychain: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    /// Whether the login keychain still holds an item for `service` (optionally a
    /// specific `account`). Used by tests that assert ASTRA secrets are not left
    /// behind in `login.keychain-db`.
    public static func loginKeychainContains(service: String, account: String? = nil) -> Bool {
        guard !shouldBlockUnscopedTestKeychainAccess else { return false }
        return AstraSecureKeychain.loginKeychainContainsService(service, account: account)
    }

    // MARK: - Last drained diagnosis

    private static let latestFailureLock = NSLock()
    private static var latestFailureStorage: AstraKeychainFailureReport?

    /// The most recent diagnosis drained by `logPendingKeychainFailure`, or
    /// `nil` when the last drain found nothing to report.
    ///
    /// Exists so a failed write can be explained on screen and not only in the
    /// log. Reading it does not drain anything — the log line remains the
    /// system of record, and this is a copy of the last one.
    public static var latestFailure: AstraKeychainFailureReport? {
        latestFailureLock.lock(); defer { latestFailureLock.unlock() }
        return latestFailureStorage
    }

    /// Emits `keychain.unavailable` if the dedicated keychain has failed to open
    /// since this was last called, and returns the diagnosis behind it.
    ///
    /// "Fails closed" is the right behavior for a read, but on its own it is
    /// indistinguishable from "the user never configured this". When the
    /// keychain itself is unopenable that mistake is made for *every* credential
    /// at once: connectors show as unconfigured, capability setup finds nothing
    /// to copy, and enabling a provider fails with a message about a missing
    /// key. Nothing in the log said the keychain was the cause, because the
    /// Obj-C layer swallowed every OSStatus. This is the one line that says so.
    ///
    /// Call it after a batch of keychain work rather than per lookup — the
    /// report already carries the suppressed-attempt count, and draining it here
    /// keeps a degraded keychain from writing a log line per credential.
    @discardableResult
    public static func logPendingKeychainFailure(scope: String) -> AstraKeychainFailureReport? {
        // Obj-C `takeLastKeychainFailureReport`; Swift drops the redundant
        // "Keychain", as it does for `secretForAccount:` → `secret(forAccount:)`.
        guard let report = AstraSecureKeychain.takeLastFailureReport() else {
            // Nothing pending means the layer is currently reporting nothing
            // wrong. Holding on to the previous diagnosis would let a keychain
            // that has since recovered keep explaining unrelated failures.
            latestFailureLock.lock()
            latestFailureStorage = nil
            latestFailureLock.unlock()
            return nil
        }
        // `report` is `stage=… status=… suppressed=…` built from an OSStatus and
        // a fixed set of stage names. It never contains a secret, an account, or
        // a path, so it is safe to log verbatim.
        AuditLoggingSeam.required.audit(.keychainUnavailable, category: "Keychain", fields: [
            "scope": scope,
            "detail": report
        ], level: .warning)
        let parsed = AstraKeychainFailureReport(rawReport: report)
        latestFailureLock.lock()
        latestFailureStorage = parsed
        latestFailureLock.unlock()
        return parsed
    }
}
