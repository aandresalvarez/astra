import Foundation
import AstraObjCSupport
import ASTRACore

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

    private static var keychainPath: String {
        keychainPathOverride ?? AppChannel.current.astraKeychainPath
    }

    private static var bootstrapService: String {
        bootstrapServiceOverride ?? AppChannel.current.astraKeychainBootstrapService
    }

    static var isUsingExplicitTestKeychain: Bool {
        keychainPathOverride != nil && bootstrapServiceOverride != nil
    }

    static var shouldBlockUnscopedTestKeychainAccess: Bool {
        isRunningTests && !isUsingExplicitTestKeychain
    }

    private static var isRunningTests: Bool {
        // SwiftPM's test helper is ad-hoc signed separately from ASTRA.app. If
        // it creates the real per-channel keychain/bootstrap item, ASTRA cannot
        // reliably read that item later. Tests that exercise Keychain behavior
        // must use the task-local temp keychain overrides above.
        let processName = ProcessInfo.processInfo.processName
        return processName == "swiftpm-testing-helper"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

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
        if allowUserInteraction {
            return AstraSecureKeychain.saveSecretAllowingUserInteraction(
                value,
                forAccount: account,
                service: service,
                label: label,
                keychainPath: keychainPath,
                bootstrapService: bootstrapService
            )
        }
        return AstraSecureKeychain.saveSecret(
            value,
            forAccount: account,
            service: service,
            label: label,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
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
}
