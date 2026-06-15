import Foundation
import AstraObjCSupport

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
enum AstraSecureKeychainStore {

    private static var keychainPath: String { AppChannel.current.astraKeychainPath }
    private static var bootstrapService: String { AppChannel.current.astraKeychainBootstrapService }

    // MARK: - CRUD

    @discardableResult
    static func save(service: String, account: String, value: String, label: String?) -> Bool {
        AstraSecureKeychain.saveSecret(
            value,
            forAccount: account,
            service: service,
            label: label,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    static func load(service: String, account: String) -> String? {
        AstraSecureKeychain.secret(
            forAccount: account,
            service: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        AstraSecureKeychain.deleteSecret(
            forAccount: account,
            service: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    @discardableResult
    static func deleteAll(service: String) -> Bool {
        AstraSecureKeychain.deleteAllSecrets(
            forService: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    static func exists(service: String, account: String) -> Bool {
        AstraSecureKeychain.hasSecret(
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
    static func migrateServiceFromLoginKeychain(service: String) -> Int {
        AstraSecureKeychain.migrateService(
            fromLoginKeychain: service,
            keychainPath: keychainPath,
            bootstrapService: bootstrapService
        )
    }

    /// Whether the login keychain still holds an item for `service` (optionally a
    /// specific `account`). Used by the readiness diagnostic and by tests that
    /// assert ASTRA secrets are not left behind in `login.keychain-db`.
    static func loginKeychainContains(service: String, account: String? = nil) -> Bool {
        AstraSecureKeychain.loginKeychainContainsService(service, account: account)
    }
}
