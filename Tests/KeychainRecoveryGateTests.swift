import Testing
import Foundation
import Security
import AstraObjCSupport
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Pins the one predicate standing between a keychain permission error and
/// permanent loss of every credential the user has stored.
///
/// `recoverUnreadableDedicatedKeychainAtPath:` deletes the bootstrap password
/// and *then* renames the keychain file. The result is not a quarantined backup:
/// it is a file encrypted with a random password that no longer exists anywhere.
/// `~/Library/Keychains` on the machine this was diagnosed on holds 25
/// `astra.keychain-db.unreadable-*` files from 2026-06-17 to 2026-07-07, one per
/// ad-hoc rebuild whose new cdhash fell out of the bootstrap item's ACL
/// partition list. Every secret in all 25 is gone.
///
/// So the gate must answer a question about the *file*, and the tempting wrong
/// version answers a question about the *bootstrap item* instead — treating
/// `errSecItemNotFound` from the login-keychain lookup as "the keychain is
/// gone". Those are different objects. The password can be missing, or
/// unreadable by this binary, while the keychain sits intact and full.
@Suite("Keychain recovery gate")
struct KeychainRecoveryGateTests {

    /// A genuine keychain, then a byte copy of it at a path this process has
    /// never opened.
    ///
    /// The copy is the point. `dedicatedKeychainForPath:` caches unlocked
    /// handles for the process lifetime, keyed by path, and nothing clears that
    /// cache — so once a path has been opened successfully it can never be made
    /// to fail again in the same process. Driving the save path's failure branch
    /// requires a path that is new to the cache but whose file is real.
    private struct HealthyKeychainCopy {
        let sourcePath: String
        let copyPath: String
        let sourceBootstrapService: String
        /// UUID-namespaced and never installed, so the login-keychain lookup is
        /// guaranteed to miss and this fixture can neither read nor prompt for
        /// anything the user owns.
        let orphanedBootstrapService = "astra-recovery-orphan-\(UUID().uuidString)"

        init?() {
            sourcePath = AstraSecureKeychainTestSupport.tempKeychainPath()
            copyPath = AstraSecureKeychainTestSupport.tempKeychainPath()
            sourceBootstrapService = "astra-recovery-bootstrap-\(UUID().uuidString)"

            AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: sourceBootstrapService)
            var created = false
            AstraSecureKeychainTestSupport.withKeychainInteractionDisabled {
                created = AstraSecureKeychain.saveSecret(
                    "recovery-gate-fixture",
                    forAccount: "account",
                    service: "astra-recovery-gate",
                    label: nil,
                    keychainPath: sourcePath,
                    bootstrapService: sourceBootstrapService
                )
            }
            guard created else { return nil }
            do {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: copyPath)
            } catch {
                return nil
            }
        }

        /// Any `<copyPath>.unreadable-*` sibling recovery would have left behind.
        func quarantinedSiblings() -> [String] {
            let directory = (copyPath as NSString).deletingLastPathComponent
            let prefix = (copyPath as NSString).lastPathComponent + ".unreadable-"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.filter { $0.hasPrefix(prefix) }
        }

        func cleanUp() {
            AstraSecureKeychainTestSupport.cleanup(
                keychainPath: sourcePath,
                bootstrapService: sourceBootstrapService,
                services: ["astra-recovery-gate"]
            )
            for name in quarantinedSiblings() {
                let directory = (copyPath as NSString).deletingLastPathComponent
                try? FileManager.default.removeItem(
                    atPath: (directory as NSString).appendingPathComponent(name)
                )
            }
            try? FileManager.default.removeItem(atPath: copyPath)
            AstraSecureKeychainTestSupport.deleteLoginItems(service: orphanedBootstrapService)
        }
    }

    @Test("A keychain that was never created is beyond recovery")
    func missingFileIsBeyondRecovery() {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        #expect(AstraSecureKeychain.dedicatedKeychainIsBeyondRecovery(atPath: path))
    }

    @Test("A file that is not a keychain is beyond recovery")
    func corruptFileIsBeyondRecovery() throws {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        try Data("not a keychain".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        // The gate has to be more than a `fileExistsAtPath:` check, and it has to
        // be more than `SecKeychainOpen`, which succeeds lazily against a path
        // holding anything at all. Only `SecKeychainGetStatus` makes securityd
        // read the bytes.
        #expect(AstraSecureKeychain.dedicatedKeychainIsBeyondRecovery(atPath: path))
    }

    @Test("A healthy keychain is never beyond recovery",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func healthyKeychainIsNotBeyondRecovery() throws {
        let fixture = try #require(HealthyKeychainCopy(), "Could not create a real keychain to copy")
        defer { fixture.cleanUp() }

        #expect(!AstraSecureKeychain.dedicatedKeychainIsBeyondRecovery(atPath: fixture.copyPath))
    }

    @Test("A save that cannot reach the bootstrap password leaves a healthy keychain in place",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func deniedSaveDoesNotQuarantineAHealthyKeychain() throws {
        let fixture = try #require(HealthyKeychainCopy(), "Could not create a real keychain to copy")
        defer { fixture.cleanUp() }

        var saved = true
        AstraSecureKeychainTestSupport.withKeychainInteractionDisabled {
            // `saveSecret:` is the variant that carries `recoverUnreadableKeychain:YES`,
            // so this is the exact call that produced the 25 dead files.
            saved = AstraSecureKeychain.saveSecret(
                "value",
                forAccount: "account",
                service: "astra-recovery-gate",
                label: nil,
                keychainPath: fixture.copyPath,
                bootstrapService: fixture.orphanedBootstrapService
            )
        }

        #expect(saved == false, "A save with no reachable bootstrap password must fail closed")

        // This is what makes the test a regression test rather than a restatement
        // of the gate. The recorded status here is `errSecItemNotFound` — which
        // the previous, status-based gate held to mean "the keychain is gone" and
        // acted on. It describes the bootstrap item; the keychain is fine.
        #expect(
            AstraSecureKeychain.lastFailureStatus(
                forKeychainPath: fixture.copyPath,
                bootstrapService: fixture.orphanedBootstrapService
            ) == errSecItemNotFound
        )
        #expect(
            FileManager.default.fileExists(atPath: fixture.copyPath),
            """
            A failed save moved the user's keychain aside. Recovery drops the \
            bootstrap password first, so the file it leaves behind can never be \
            opened again — every stored credential is gone, not quarantined.
            """
        )
        #expect(fixture.quarantinedSiblings().isEmpty)
    }
}
