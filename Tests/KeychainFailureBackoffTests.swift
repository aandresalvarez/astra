import Testing
import Foundation
import Security
import AstraObjCSupport
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Pins the two properties that make an unreadable keychain survivable rather
/// than app-hanging.
///
/// The failure this guards against was measured, not imagined. `AstraSecureKeychain`
/// cached only *successful* opens; every failure path returned NULL having
/// stored nothing, so the next lookup redid `SecKeychainCopyDefault` +
/// `SecKeychainFindGenericPassword` + open + unlock from scratch. That is fine
/// if failures are rare, but they are not sparse when they happen: an ad-hoc
/// rebuild is missing from the bootstrap item's ACL partition list, so *every*
/// credential in the app becomes unreadable at once, and the callers above this
/// layer issue reads in the hundreds. `WorkspaceSetupForm` ran three full
/// `CapabilitySetupCopier` sweeps per SwiftUI body pass — thousands of failing
/// securityd round trips, synchronously, on the main thread. The New Workspace
/// sheet hung for seconds.
///
/// These tests assert the fix by counting real open attempts rather than by
/// timing anything: under parallel load in this test binary a wall-clock budget
/// measures how busy the machine is, not how much work the code did.
@Suite("Keychain failure backoff")
struct KeychainFailureBackoffTests {

    /// A path whose file exists but whose bootstrap password does not, which is
    /// the cheapest way to make `dedicatedKeychainForPath:` fail deterministically
    /// and without user interaction. The bootstrap service is UUID-namespaced, so
    /// the login-keychain lookup is guaranteed to miss and this test can never
    /// read, prompt for, or disturb anything the user owns.
    private struct UnopenableKeychain {
        let path: String
        let bootstrapService: String

        init() throws {
            let id = UUID().uuidString
            path = NSString(string: NSTemporaryDirectory())
                .appendingPathComponent("astra-backoff-\(id).keychain-db")
            bootstrapService = "astra-backoff-bootstrap-\(id)"
            // Not a real keychain — it only has to exist, so that
            // `dedicatedKeychainForPath:` takes the "existing file" branch and
            // requires a stored bootstrap password instead of minting one.
            try Data("not a keychain".utf8).write(to: URL(fileURLWithPath: path))
        }

        func cleanUp() {
            AstraSecureKeychain.clearTestBootstrapPassword(forBootstrapService: bootstrapService)
            try? FileManager.default.removeItem(atPath: path)
        }

        func read() -> String? {
            var value: String?
            AstraSecureKeychain.perform(keychainUserInteractionDisabled: {
                value = AstraSecureKeychain.secret(
                    forAccount: "some-account",
                    service: "some-service",
                    keychainPath: path,
                    bootstrapService: bootstrapService
                )
            })
            return value
        }

        /// A save routed through the "Allow & Save" entry point — the only
        /// caller that runs with Keychain UI enabled.
        ///
        /// It cannot actually prompt against this fixture: the bootstrap
        /// service is UUID-namespaced so the login-keychain lookup misses, and
        /// the file already exists so nothing is minted. It fails at the same
        /// stage `read()` does, just on the interactive side of the floor.
        func interactiveSave() -> Bool {
            AstraSecureKeychain.saveSecretAllowingUserInteraction(
                "some-value",
                forAccount: "some-account",
                service: "some-service",
                label: nil,
                keychainPath: path,
                bootstrapService: bootstrapService
            )
        }
    }

    @Test("A burst of reads against an unopenable keychain costs one open attempt, not one per read")
    func failingReadsCollapseToASingleAttempt() throws {
        let keychain = try UnopenableKeychain()
        defer { keychain.cleanUp() }

        for _ in 0..<50 {
            #expect(keychain.read() == nil, "A keychain that cannot be opened must fail closed")
        }

        #expect(
            AstraSecureKeychain.openAttemptCount(forKeychainPath: keychain.path) == 1,
            """
            Each failing read re-opened the keychain from scratch. This is the \
            New Workspace hang: one SwiftUI body pass issues thousands of these, \
            synchronously, on the main thread.
            """
        )
    }

    @Test("The backoff is a delay, not a latch — a changed bootstrap password is picked up at once")
    func backoffDoesNotOutliveTheConditionThatCausedIt() throws {
        let keychain = try UnopenableKeychain()
        defer { keychain.cleanUp() }

        _ = keychain.read()
        #expect(AstraSecureKeychain.openAttemptCount(forKeychainPath: keychain.path) == 1)

        // Installing a bootstrap password is exactly the kind of change the
        // backoff must not outlast. Asserting it this way keeps the test
        // deterministic: the alternative is sleeping out the real window, which
        // is both slow and, under parallel load, unreliable.
        AstraSecureKeychain.setTestBootstrapPassword("bootstrap-secret", forBootstrapService: keychain.bootstrapService)
        _ = keychain.read()

        #expect(
            AstraSecureKeychain.openAttemptCount(forKeychainPath: keychain.path) == 2,
            """
            The retry floor survived a change that invalidates it. A keychain the \
            user has just made readable must become readable immediately, not \
            after the app is relaunched.
            """
        )
    }

    @Test("A failure names the stage that failed instead of being swallowed")
    func failureIsReportedRatherThanSwallowed() throws {
        let keychain = try UnopenableKeychain()
        defer { keychain.cleanUp() }

        _ = AstraSecureKeychain.takeLastFailureReport()
        for _ in 0..<3 { _ = keychain.read() }

        // Failing closed is correct, but on its own it is indistinguishable from
        // "nothing was ever configured" — which is how a completely unreadable
        // keychain stayed invisible in the app log while every credential in the
        // app silently vanished. `AstraSecureKeychain` logs nothing itself (it
        // handles secrets); this report is the whole diagnostic surface.

        // The stage is asserted through the keyed lookup, which sees only this
        // fixture. A file that exists but holds no keychain, under a bootstrap
        // service that cannot resolve, must stop at the password — it never gets
        // as far as opening the file.
        #expect(
            AstraSecureKeychain.lastFailureStage(
                forKeychainPath: keychain.path,
                bootstrapService: keychain.bootstrapService
            ) == "bootstrap-password"
        )

        // The report itself is asserted on shape only. It is process-global by
        // design — one line for the app, not one per path — and other suites in
        // this binary drive keychains concurrently, so pinning its stage or its
        // exact `suppressed` count here would be pinning the scheduler.
        let report = try #require(
            AstraSecureKeychain.takeLastFailureReport(),
            "An unopenable keychain produced no diagnostic at all"
        )
        #expect(report.contains("stage="))
        #expect(report.contains("suppressed="))
    }

    /// The backoff is a defense against *incidental* traffic, and it has to stay
    /// that way in both directions.
    ///
    /// The Connectors sheet re-reads every credential row on every keystroke, so
    /// by the time the user clicks "Allow & Save" there is always a floor a few
    /// milliseconds old. Serving the click from that floor means securityd is
    /// never asked, so the "allow access?" dialog — the entire remedy for a
    /// partition-list denial — can never appear. Measured on 2026-08-17: 12
    /// consecutive clicks, five under 300 ms apart, produced no prompt, no
    /// securityd call, and not one log line.
    ///
    /// The converse matters just as much. If a click bypassed the floor
    /// unconditionally, one save that writes several keys would stack one modal
    /// dialog per key.
    ///
    /// Gated with the other tests that enable Keychain UI: the flag is
    /// process-wide, and this binary runs thousands of tests in parallel.
    @Test("A user's click is not answered from a floor that a background read set",
          .enabled(if: AstraSecureKeychainTestSupport.isAvailable))
    func interactiveAttemptSpendsExactlyOneRoundTripPerWindow() throws {
        let keychain = try UnopenableKeychain()
        defer { keychain.cleanUp() }

        #expect(keychain.read() == nil)
        #expect(AstraSecureKeychain.openAttemptCount(forKeychainPath: keychain.path) == 1)

        #expect(keychain.interactiveSave() == false)
        #expect(
            AstraSecureKeychain.openAttemptCount(forKeychainPath: keychain.path) == 2,
            "A background read silenced the user's click; securityd was never asked."
        )

        #expect(keychain.interactiveSave() == false)
        #expect(
            AstraSecureKeychain.openAttemptCount(forKeychainPath: keychain.path) == 2,
            "A second click inside the same window spent another round trip; a multi-key save would stack dialogs."
        )
    }

    @Test("The reported status is measured, not a placeholder")
    func failureStatusComesFromSecurityd() throws {
        let keychain = try UnopenableKeychain()
        defer { keychain.cleanUp() }

        _ = keychain.read()

        // This fixture's bootstrap service is UUID-namespaced, so the item is
        // genuinely absent and securityd genuinely answers -25300. The value
        // being right is not the point — it used to be a hardcoded
        // `errSecItemNotFound` passed at the call site, which produced the same
        // number here while reporting "no such item" for the case that actually
        // matters in production: an item that exists but whose ACL partition
        // list excludes the running binary, which answers -25293 or -25308.
        // Pinning it end-to-end is what stops it silently becoming a constant
        // again; `CredentialSweepFitnessTests` guards the wiring itself.
        #expect(
            AstraSecureKeychain.lastFailureStatus(
                forKeychainPath: keychain.path,
                bootstrapService: keychain.bootstrapService
            ) == errSecItemNotFound
        )
    }
}
