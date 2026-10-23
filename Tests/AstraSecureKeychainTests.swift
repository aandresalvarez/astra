import Testing
import Foundation
import Security
import SwiftData
import AstraObjCSupport
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

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
        AstraSecureKeychain.clearTestBootstrapPassword(forBootstrapService: bootstrapService)
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
        AstraSecureKeychain.perform(keychainUserInteractionDisabled: {
            SecItemDelete(query as CFDictionary)
        })
    }

    /// Run keychain assertions with Security.framework UI disabled. This catches
    /// regressions where ASTRA would otherwise surface the internal dedicated
    /// keychain password prompt instead of reading through its unlocked handle.
    static func withKeychainInteractionDisabled(_ body: () -> Void) {
        AstraSecureKeychain.perform(keychainUserInteractionDisabled: body)
    }

    static func installTestBootstrapPassword(service: String) {
        AstraSecureKeychain.setTestBootstrapPassword(
            "test-bootstrap-\(UUID().uuidString)",
            forBootstrapService: service
        )
    }

    static let realKeychainTestsEnabled =
        ProcessInfo.processInfo.environment["ASTRA_ENABLE_REAL_KEYCHAIN_TESTS"] == "1"

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
        var status: OSStatus = errSecSuccess
        AstraSecureKeychain.perform(keychainUserInteractionDisabled: {
            SecItemDelete(query as CFDictionary)
            status = SecItemAdd(query as CFDictionary, nil)
        })
        return status == errSecSuccess
    }

    static let isAvailable: Bool = {
        guard realKeychainTestsEnabled else { return false }
        let path = tempKeychainPath()
        let service = "astra-availability-\(UUID().uuidString)"
        let bootstrap = "astra-availability-bootstrap-\(UUID().uuidString)"
        installTestBootstrapPassword(service: bootstrap)
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

@Suite("ASTRA dedicated secret keychain", .serialized)
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

    @Test("Tests must opt into a temporary keychain before using the store")
    func testsRequireExplicitTemporaryKeychainOverride() {
        #expect(AstraSecureKeychainStore.shouldBlockUnscopedTestKeychainAccess)

        AstraSecureKeychainStore.$keychainPathOverride.withValue(
            AstraSecureKeychainTestSupport.tempKeychainPath()
        ) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(
                "astra-test-bootstrap-\(UUID().uuidString)"
            ) {
                #expect(!AstraSecureKeychainStore.shouldBlockUnscopedTestKeychainAccess)
            }
        }
    }

    @Test("Dedicated keychain background operations disable UI and use file-keychain lookup")
    func dedicatedReadsAreNonInteractiveFileKeychainLookups() throws {
        let source = try astraSecureKeychainSource()
        let readSecretBody = try methodBody(
            startingWith: "+ (NSData *)readSecretDataForAccount:",
            endingBefore: "+ (OSStatus)addBootstrapPassword:",
            in: source
        )
        let secretBody = try methodBody(
            startingWith: "+ (nullable NSString *)secretForAccount:",
            endingBefore: "+ (BOOL)deleteSecretForAccount:",
            in: source
        )
        let writeSecretBody = try methodBody(
            startingWith: "+ (BOOL)writeSecret:",
            endingBefore: "+ (nullable NSString *)secretForAccount:",
            in: source
        )
        let saveBody = try methodBody(
            startingWith: "+ (BOOL)saveSecret:",
            endingBefore: "+ (BOOL)saveSecretAllowingUserInteraction:",
            in: source
        )
        let existsBody = try methodBody(
            startingWith: "+ (BOOL)hasSecretForAccount:",
            endingBefore: "#pragma mark - Migration & login-keychain probe",
            in: source
        )

        for body in [secretBody, existsBody] {
            #expect(body.contains("disableKeychainUserInteractionSavingPrevious"))
            #expect(body.contains("restoreKeychainUserInteraction"))
            #expect(!body.contains("SecItemCopyMatching"))
        }
        #expect(saveBody.contains("allowUserInteraction:false"))
        #expect(saveBody.contains("recoverUnreadableKeychain:true"))
        #expect(writeSecretBody.contains("disableKeychainUserInteractionSavingPrevious"))
        #expect(writeSecretBody.contains("restoreKeychainUserInteraction"))
        #expect(!writeSecretBody.contains("SecItemCopyMatching"))
        for body in [secretBody, existsBody] {
            #expect(body.contains("readSecretDataForAccount"))
        }
        #expect(!secretBody.contains("temporarilyAllowKeychainUserInteraction"))
        #expect(writeSecretBody.contains("SecItemDelete"))
        #expect(writeSecretBody.contains("addSecretValue"))
        #expect(writeSecretBody.contains("recoverUnreadableDedicatedKeychainAtPath"))
        #expect(readSecretBody.contains("SecKeychainFindGenericPassword"))
        #expect(!readSecretBody.contains("repairSecretAccessForItem"))
        #expect(!readSecretBody.contains("SecKeychainItemSetAccess"))
    }

    @Test("Explicit user saves allow Keychain permission prompts without destructive recovery")
    func explicitUserSavesAllowPromptWithoutRecovery() throws {
        let source = try astraSecureKeychainSource()
        let userSaveBody = try methodBody(
            startingWith: "+ (BOOL)saveSecretAllowingUserInteraction:",
            endingBefore: "+ (BOOL)writeSecret:",
            in: source
        )
        let writeSecretBody = try methodBody(
            startingWith: "+ (BOOL)writeSecret:",
            endingBefore: "+ (nullable NSString *)secretForAccount:",
            in: source
        )

        #expect(userSaveBody.contains("allowUserInteraction:true"))
        #expect(userSaveBody.contains("recoverUnreadableKeychain:false"))
        #expect(writeSecretBody.contains("allowKeychainUserInteractionSavingPrevious"))
        #expect(writeSecretBody.contains("if (!recoverUnreadableKeychain)"))
        #expect(writeSecretBody.contains("return NO;"))
    }

    @Test("Saving a replacement can recover from an unreadable dedicated keychain")
    func saveSecretRecoversUnreadableDedicatedKeychain() throws {
        let source = try astraSecureKeychainSource()
        let recoveryBody = try methodBody(
            startingWith: "+ (BOOL)recoverUnreadableDedicatedKeychainAtPath:",
            endingBefore: "#pragma mark - Bootstrap password",
            in: source
        )
        let saveBody = try methodBody(
            startingWith: "+ (BOOL)writeSecret:",
            endingBefore: "+ (nullable NSString *)secretForAccount:",
            in: source
        )

        #expect(recoveryBody.contains("deleteBootstrapPasswordForService"))
        #expect(recoveryBody.contains("moveUnreadableKeychainAsideAtPath"))
        #expect(recoveryBody.contains("removeObjectForKey"))
        #expect(saveBody.contains("recoverUnreadableDedicatedKeychainAtPath"))
        #expect(saveBody.contains("dedicatedKeychainForPath:keychainPath"))
        // The save path is the only caller that can run with Keychain UI on, and
        // the flag has to reach the open — the backoff consults it to decide
        // whether a floor set by a background read may answer a user's click.
        // Serving the click from that floor is why twelve "Allow & Save" presses
        // on 2026-08-17 never produced a prompt.
        #expect(saveBody.contains("userInteractionAllowed:allowUserInteraction"))
    }

    @Test("Keychain password and secret items keep app-scoped access")
    func keychainItemsUseAppScopedAccess() throws {
        let source = try astraSecureKeychainSource()
        let accessBody = try methodBody(
            startingWith: "+ (SecAccessRef)nonPromptingAccessWithLabel:",
            endingBefore: "+ (NSData *)readBootstrapPasswordForService:",
            in: source
        )
        let saveBody = try methodBody(
            startingWith: "+ (BOOL)writeSecret:",
            endingBefore: "+ (nullable NSString *)secretForAccount:",
            in: source
        )
        let bootstrapBody = try methodBody(
            startingWith: "+ (NSData *)bootstrapPasswordForService:",
            endingBefore: "#pragma mark - CRUD",
            in: source
        )

        #expect(accessBody.contains("SecAccessCreate"))
        #expect(accessBody.contains("SecAccessCreate((__bridge CFStringRef)label, NULL, &access)"))
        #expect(!accessBody.contains("SecACLSetContents"))
        #expect(!accessBody.contains("kSecACLAuthorizationDecrypt"))
        #expect(!accessBody.contains("allow all applications"))
        #expect(!accessBody.contains("SecKeychainItemSetAccess"))
        #expect(!accessBody.contains("repairBootstrapAccessForItem"))
        #expect(!bootstrapBody.contains("temporarilyAllowKeychainUserInteraction"))
        #expect(bootstrapBody.contains("readBootstrapPasswordForService"))
        #expect(bootstrapBody.contains("addBootstrapPassword"))
        #expect(saveBody.contains("SecItemDelete"))
        #expect(saveBody.contains("addSecretValue"))
        #expect(!saveBody.contains("repairSecretAccessForItem"))
    }

    // MARK: - CRUD against the dedicated keychain

    @Test("Save, load, and delete round-trip in the dedicated keychain",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func crudRoundTrip() {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let service = "astra-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
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
        AstraSecureKeychainTestSupport.withKeychainInteractionDisabled {
            #expect(AstraSecureKeychain.hasSecret(
                forAccount: "JIRA_API_TOKEN", service: service,
                keychainPath: path, bootstrapService: bootstrap
            ))
            #expect(AstraSecureKeychain.secret(
                forAccount: "JIRA_API_TOKEN", service: service,
                keychainPath: path, bootstrapService: bootstrap
            ) == "s3cr3t-value")
        }

        // Re-saving replaces the previous value without changing the API contract.
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

    @Test("Save recovers an unreadable existing dedicated keychain file",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func saveRecoversUnreadableExistingDedicatedKeychainFile() throws {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let service = "astra-\(UUID().uuidString)"
        defer {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: path, bootstrapService: bootstrap, services: [service]
            )
            if let backups = try? FileManager.default.contentsOfDirectory(
                atPath: NSString(string: path).deletingLastPathComponent
            ) {
                for backup in backups where backup.hasPrefix(NSString(string: path).lastPathComponent + ".unreadable-") {
                    let backupPath = NSString(string: NSString(string: path).deletingLastPathComponent)
                        .appendingPathComponent(backup)
                    try? FileManager.default.removeItem(atPath: backupPath)
                }
            }
        }

        try Data("not-a-keychain".utf8).write(to: URL(fileURLWithPath: path))

        #expect(AstraSecureKeychain.saveSecret(
            "new-token", forAccount: "JIRA_API_TOKEN", service: service,
            label: "Astra: Recovery", keychainPath: path, bootstrapService: bootstrap
        ))
        #expect(AstraSecureKeychain.secret(
            forAccount: "JIRA_API_TOKEN", service: service,
            keychainPath: path, bootstrapService: bootstrap
        ) == "new-token")

        let directory = NSString(string: path).deletingLastPathComponent
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(backups.contains { $0.hasPrefix(NSString(string: path).lastPathComponent + ".unreadable-") })
    }

    // MARK: - Isolation: secrets are NOT in the login keychain

    @Test("Secrets written to the dedicated keychain are absent from the login keychain",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func secretsAbsentFromLoginKeychain() {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let service = "astra-\(UUID().uuidString)"
        let account = "REDCAP_API_TOKEN"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
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
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: tempBootstrap)
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
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
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

    @MainActor
    @Test("Startup migration includes shared global connector secrets",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func startupMigrationIncludesSharedGlobalConnectorSecrets() throws {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let connector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Shared Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        connector.isGlobal = true
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        container.mainContext.insert(connector)
        try container.mainContext.save()
        let service = KeychainSecretStore.connectorEntityID(for: connector.id)
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: path, bootstrapService: bootstrap, services: [service]
            )
            AstraSecureKeychainTestSupport.deleteLoginItems(service: service)
        }

        try #require(AstraSecureKeychainTestSupport.seedLoginItem(
            service: service,
            account: "JIRA_EMAIL",
            value: "user@example.com"
        ))
        try #require(AstraSecureKeychainTestSupport.seedLoginItem(
            service: service,
            account: "JIRA_API_TOKEN",
            value: "token"
        ))

        AstraSecureKeychainStore.$keychainPathOverride.withValue(path) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                StartupCredentialMigrationService.migrate(modelContext: container.mainContext)

                let store = KeychainSecretStore()
                #expect(store.load(key: "JIRA_EMAIL", entityID: service) == "user@example.com")
                #expect(store.load(key: "JIRA_API_TOKEN", entityID: service) == "token")
                #expect(!AstraSecureKeychainStore.loginKeychainContains(service: service, account: "JIRA_EMAIL"))
                #expect(!AstraSecureKeychainStore.loginKeychainContains(service: service, account: "JIRA_API_TOKEN"))
            }
        }
    }
}

/// The failure report is one process-global slot that the first reader empties,
/// so a diagnosis only belongs to the write that caused it if the write and the
/// drain that claims it happen inside the same critical section. `writeLock`
/// does that — but only for the operations that take it, and a migration did
/// not. Startup runs one migration per connector and per skill, each of which
/// opens the dedicated keychain and copies items into it, while the credential
/// sheet is reachable: enough overlap to hand a user's failed save a stage from
/// some unrelated skill's legacy item, or to consume the report the sheet was
/// waiting for and leave it with the generic wording.
///
/// Asserted off the source because the defect is an absent lock. A behavioural
/// test would have to lose the race on purpose, which is exactly the thing that
/// only happens sometimes.
@Suite("Keychain failure reports are serialized with the writes that produce them")
struct AstraSecureKeychainStoreLockingTests {

    /// Calls that can leave a report in the global slot, or take one out of it.
    ///
    /// Reads and deletes are deliberately absent, and the store says why: the
    /// only report a failing read can produce is "this keychain will not open",
    /// which is true for every caller at once and so misattributes nothing. A
    /// migration's failures are per-item and name a stage belonging to a
    /// different credential entirely.
    private static let reportProducingCalls = [
        "AstraSecureKeychain.saveSecret(",
        "AstraSecureKeychain.saveSecretAllowingUserInteraction(",
        "AstraSecureKeychain.migrateService(",
        "AstraSecureKeychain.takeLastFailureReport("
    ]

    @Test("Every write and drain in the store holds the write lock")
    func reportProducingEntryPointsTakeTheWriteLock() throws {
        let functions = try astraSecureKeychainStoreFunctions()
        try #require(!functions.isEmpty)

        var checked: [String] = []
        for function in functions {
            guard Self.reportProducingCalls.contains(where: { function.body.contains($0) }) else { continue }
            checked.append(function.name)
            // `…Locked` is the naming for a body whose caller already holds it.
            // `NSLock` is not recursive, so taking it again would deadlock.
            guard !function.name.hasSuffix("Locked") else {
                #expect(!function.body.contains("writeLock.lock()"), "\(function.name) would deadlock")
                continue
            }
            #expect(
                function.body.contains("writeLock.lock()"),
                "\(function.name) can fill or empty the global failure report without holding writeLock"
            )
        }

        // The set itself, so deleting a function silently is not how this test
        // starts passing. Migration is the one this suite was added for.
        #expect(checked.contains("saveReportingFailure"))
        #expect(checked.contains("migrateServiceFromLoginKeychain"))
        #expect(checked.contains("drainPendingKeychainFailureLocked"))
    }

    /// The migration is not called from inside the lock anywhere, which is what
    /// makes taking it safe. `KeychainService.migrate` is the only production
    /// caller and it runs outside any critical section; nesting one under
    /// `saveReportingFailure` would deadlock on the spot.
    @Test("Nothing calls the migration while already holding the lock")
    func migrationIsNeverCalledUnderTheLock() throws {
        let functions = try astraSecureKeychainStoreFunctions()
        for function in functions where function.body.contains("writeLock.lock()") {
            guard function.name != "migrateServiceFromLoginKeychain" else { continue }
            #expect(!function.body.contains("migrateServiceFromLoginKeychain("))
        }
    }
}

/// Function bodies of `AstraSecureKeychainStore`, comment lines stripped.
///
/// Stripping matters: the doc comment on `writeLock` names every call this file
/// asserts on, and it sits between two functions, so leaving comments in would
/// attach it to whichever function precedes it and turn the assertion into a
/// test of prose.
private func astraSecureKeychainStoreFunctions() throws -> [(name: String, body: String)] {
    let testFile = URL(filePath: #filePath)
    let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = repoRoot.appending(path: "Astra/Services/Persistence/AstraSecureKeychainStore.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    var functions: [(name: String, body: String)] = []
    var current: (name: String, lines: [String])?
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
        if let name = declaredSwiftFunctionName(in: line) {
            if let open = current { functions.append((open.name, open.lines.joined(separator: "\n"))) }
            current = (name, [line])
        } else {
            current?.lines.append(line)
        }
    }
    if let open = current { functions.append((open.name, open.lines.joined(separator: "\n"))) }
    return functions
}

private func declaredSwiftFunctionName(in line: String) -> String? {
    guard let funcRange = line.range(of: "func ") else { return nil }
    let prefix = line[..<funcRange.lowerBound].trimmingCharacters(in: .whitespaces)
    // A `func` inside an expression or a string is not a declaration.
    guard prefix.isEmpty || prefix.allSatisfy({ !$0.isPunctuation || $0 == "@" || $0 == "_" }) else { return nil }
    let afterFunc = line[funcRange.upperBound...]
    guard let paren = afterFunc.firstIndex(of: "(") else { return nil }
    let name = afterFunc[..<paren].trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

private func astraSecureKeychainSource() throws -> String {
    let testFile = URL(filePath: #filePath)
    let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = repoRoot.appending(path: "AstraObjCSupport/AstraSecureKeychain.m")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func methodBody(startingWith start: String, endingBefore end: String, in source: String) throws -> String {
    let startRange = try #require(source.range(of: start))
    let remaining = source[startRange.lowerBound...]
    let endRange = try #require(remaining.range(of: end))
    return String(remaining[..<endRange.lowerBound])
}
