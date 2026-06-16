import Testing
import Foundation
import Security
import AstraObjCSupport
@testable import ASTRA

/// Helpers for exercising the real keychain in a CI-safe way. Every test that
/// touches the keychain is gated behind `isAvailable`, which probes once whether
/// this environment can create+unlock a file keychain (it can't on a headless
/// runner with no usable login keychain — there the tests are skipped, not
/// failed). Each test uses unique UUID-namespaced services and cleans up.
enum AstraSecureKeychainTestSupport {
    static func tempKeychainPath() -> String {
        NSString(string: NSTemporaryDirectory())
            .appendingPathComponent("astra-test-\(UUID().uuidString).keychain-db")
    }

    /// Remove a temp keychain file and its login-keychain bootstrap password.
    static func cleanup(keychainPath: String, bootstrapService: String, services: [String]) {
        // Only delete from the dedicated keychain if it actually exists — calling
        // through AstraSecureKeychain would otherwise create the keychain (and a
        // bootstrap item) just to delete from it, defeating the cleanup.
        if FileManager.default.fileExists(atPath: keychainPath) {
            for service in services {
                AstraSecureKeychain.deleteAllSecrets(
                    forService: service,
                    keychainPath: keychainPath,
                    bootstrapService: bootstrapService
                )
            }
            try? FileManager.default.removeItem(atPath: keychainPath)
        }
        // Idempotent login-keychain delete; safe even if setup failed before the
        // dedicated file was created.
        deleteLoginItems(service: bootstrapService)
    }

    /// Delete every item with `service` from the login (default) keychain. Uses
    /// the modern (non-deprecated) SecItem API; the default keychain is login.
    static func deleteLoginItems(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Seed a legacy secret directly into the login keychain (simulating an item
    /// stored by an older ASTRA version). Returns whether the add succeeded.
    @discardableResult
    static func seedLoginItem(service: String, account: String, value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static let isAvailable: Bool = {
        let path = tempKeychainPath()
        let service = "astra-availability-\(UUID().uuidString)"
        let bootstrap = "astra-availability-bootstrap-\(UUID().uuidString)"
        let ok = AstraSecureKeychain.saveSecret(
            "probe",
            forAccount: "probe",
            service: service,
            label: nil,
            keychainPath: path,
            bootstrapService: bootstrap
        )
        cleanup(keychainPath: path, bootstrapService: bootstrap, services: [service])
        return ok
    }()
}

@Suite("ASTRA dedicated secret keychain")
struct AstraSecureKeychainTests {

    // MARK: - Configuration (no keychain access — always runs)

    @Test("Dedicated keychain path is a separate file, never login.keychain-db")
    func dedicatedPathIsNotLoginKeychain() {
        for channel in [AppChannel.production, .development, .beta] {
            let path = channel.astraKeychainPath(fileManager: .default)
            #expect(path.contains("/Library/Keychains/"))
            #expect(path.hasSuffix(".keychain-db"))
            #expect(!path.hasSuffix("login.keychain-db"))
            #expect(NSString(string: path).lastPathComponent != "login.keychain-db")
        }
        #expect(AppChannel.production.astraKeychainPath(fileManager: .default)
            .hasSuffix("astra.keychain-db"))
        // Channels must not collide on the same keychain file.
        let names = Set([AppChannel.production, .development, .beta].map {
            NSString(string: $0.astraKeychainPath(fileManager: .default)).lastPathComponent
        })
        #expect(names.count == 3)
    }

    // MARK: - CRUD against the dedicated keychain

    @Test("Save, load, and delete round-trip in the dedicated keychain",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func crudRoundTrip() {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let service = "astra-\(UUID().uuidString)"
        defer {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: path, bootstrapService: bootstrap, services: [service]
            )
        }

        #expect(AstraSecureKeychain.saveSecret(
            "s3cr3t-value", forAccount: "JIRA_API_TOKEN", service: service,
            label: "Astra: Test", keychainPath: path, bootstrapService: bootstrap
        ))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(AstraSecureKeychain.hasSecret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ))
        #expect(AstraSecureKeychain.secret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == "s3cr3t-value")

        // Update overwrites in place.
        #expect(AstraSecureKeychain.saveSecret(
            "rotated", forAccount: "JIRA_API_TOKEN", service: service,
            label: nil, keychainPath: path, bootstrapService: bootstrap
        ))
        #expect(AstraSecureKeychain.secret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == "rotated")

        #expect(AstraSecureKeychain.deleteSecret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ))
        #expect(AstraSecureKeychain.secret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == nil)
    }

    // MARK: - Isolation: secrets are NOT in the login keychain

    @Test("Secrets written to the dedicated keychain are absent from the login keychain",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func secretsAbsentFromLoginKeychain() {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let service = "astra-\(UUID().uuidString)"
        let account = "REDCAP_API_TOKEN"
        defer {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: path, bootstrapService: bootstrap, services: [service]
            )
        }

        #expect(AstraSecureKeychain.saveSecret(
            "tok-1234", forAccount: account, service: service,
            label: nil, keychainPath: path, bootstrapService: bootstrap
        ))
        // Present in the dedicated keychain...
        #expect(AstraSecureKeychain.secret(
            forAccount: account, service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == "tok-1234")
        // ...but never written to login.keychain-db.
        #expect(!AstraSecureKeychain.loginKeychainContainsService(service, account: account))
        #expect(!AstraSecureKeychain.loginKeychainContainsService(service, account: nil))
    }

    @Test("KeychainService connector secrets do not land in the login keychain",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func keychainServiceConnectorSecretsAvoidLogin() {
        // Exercise the production wiring (KeychainService → AstraSecureKeychainStore
        // → dedicated keychain, never login) but redirect the store at a throwaway
        // temp keychain via task-local overrides. This keeps the test hermetic: the
        // real per-channel keychain and its bootstrap item are never touched, and
        // nothing is shared with concurrently-running real-keychain tests, so
        // teardown can safely delete everything it created.
        let tempPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let tempBootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let connectorID = UUID()
        let service = KeychainSecretStore.connectorEntityID(for: connectorID)
        defer {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: tempPath, bootstrapService: tempBootstrap, services: [service]
            )
        }

        AstraSecureKeychainStore.$keychainPathOverride.withValue(tempPath) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(tempBootstrap) {
                #expect(KeychainService.save(key: "API_KEY", value: "live-secret", connectorID: connectorID))
                #expect(KeychainService.load(key: "API_KEY", connectorID: connectorID) == "live-secret")
                #expect(KeychainService.exists(key: "API_KEY", connectorID: connectorID))
                // The whole point: it is written to the dedicated keychain, not login.
                #expect(!AstraSecureKeychainStore.loginKeychainContains(service: service, account: "API_KEY"))
                #expect(!AstraSecureKeychainStore.loginKeychainContains(service: service))
            }
        }
    }

    // MARK: - Migration from the login keychain

    @Test("Legacy login-keychain secrets migrate into the dedicated keychain and leave login",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func migratesLegacyLoginSecrets() throws {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let service = "astra-\(UUID().uuidString)"
        defer {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: path, bootstrapService: bootstrap, services: [service]
            )
            AstraSecureKeychainTestSupport.deleteLoginItems(service: service)
        }

        // Seed two legacy items in the login keychain (different accounts, e.g.
        // a credential key and an OAuth token) to prove enumerate-by-service.
        try #require(AstraSecureKeychainTestSupport.seedLoginItem(
            service: service, account: "JIRA_API_TOKEN", value: "legacy-a"))
        try #require(AstraSecureKeychainTestSupport.seedLoginItem(
            service: service, account: "OAUTH_REFRESH", value: "legacy-b"))

        let moved = AstraSecureKeychain.migrateService(
            fromLoginKeychain: service, keychainPath: path, bootstrapService: bootstrap
        )
        #expect(moved == 2)

        // Now present in the dedicated keychain...
        #expect(AstraSecureKeychain.secret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == "legacy-a")
        #expect(AstraSecureKeychain.secret(
            forAccount: "OAUTH_REFRESH", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == "legacy-b")
        // ...and gone from the login keychain.
        #expect(!AstraSecureKeychain.loginKeychainContainsService(service, account: "JIRA_API_TOKEN"))
        #expect(!AstraSecureKeychain.loginKeychainContainsService(service, account: "OAUTH_REFRESH"))

        // Idempotent: a second run finds nothing left to move.
        let again = AstraSecureKeychain.migrateService(
            fromLoginKeychain: service, keychainPath: path, bootstrapService: bootstrap
        )
        #expect(again == 0)
    }
}
