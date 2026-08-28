import Foundation
import Testing

/// The rule these tests defend: reading a credential is a synchronous securityd
/// round trip, so nothing may issue an unbounded number of them from SwiftUI
/// `body`, and a keychain that cannot be opened must fail *once* rather than
/// once per lookup.
///
/// Both halves were violated in production at the same time, and each hid the
/// other. `WorkspaceSetupForm.capabilitiesSection` reached a computed property
/// that ran `CapabilitySetupCopier.copySetup` over every workspace — three times
/// per body pass, on the main thread, re-run on every keystroke. Separately,
/// `AstraSecureKeychain` cached only successful opens, so once an ad-hoc rebuild
/// fell out of the bootstrap item's ACL partition list, every one of those
/// lookups redid the full open/unlock handshake. While the keychain worked the
/// sweep was invisible; while the sweep was small the failure was survivable.
/// Together they hung the New Workspace sheet for seconds.
///
/// This target deliberately has no package dependencies, so everything here is
/// a source scan. The behavioural halves live in
/// `Tests/CapabilitySetupCopierFanOutTests.swift` (how much the copier asks) and
/// `Tests/KeychainFailureBackoffTests.swift` (how often a failure re-asks).
@Suite("Credential sweep fitness")
struct CredentialSweepFitnessTests {

    @Test("Capability-setup copying stays out of SwiftUI body")
    func capabilitySetupCopyingIsNotEvaluatedFromBody() throws {
        let contentView = try fileText("Astra/Views/ContentView.swift")
        let pluginCatalog = try fileText("Astra/Views/PluginCatalogView.swift")

        // `copySetup` / `installationInputs` walk every workspace × every
        // package connector × every credential hint × every key alias × every
        // entity-ID namespace, and each leaf is a Keychain round trip. Reached
        // from a computed property they re-run on every body pass; both of these
        // views re-render on every keystroke into a text field. They must be
        // driven from a keyed `.task` into `@State` instead.
        for (name, source) in [("ContentView", contentView), ("PluginCatalogView", pluginCatalog)] {
            #expect(
                source.contains("@State private var copyable"),
                "\(name) no longer caches its copyable capability setups in @State"
            )
            #expect(
                !source.contains("private var copyableCapabilitySetupSourceWorkspaces: [Workspace]"),
                "\(name) reintroduced the body-evaluated copier sweep"
            )
            #expect(
                !source.contains("private var copyableSetupSourceWorkspaces: [Workspace]"),
                "\(name) reintroduced the body-evaluated copier sweep"
            )
        }

        #expect(contentView.contains(".task(id: copyableCapabilitySetupKey)"))
        #expect(pluginCatalog.contains(".task(id: copyableSetupSourceKey)"))
    }

    @Test("The dedicated keychain caches its failures, not only its successes")
    func keychainFailurePathsAreCachedAndReported() throws {
        let keychain = try fileText("AstraObjCSupport/AstraSecureKeychain.m")
        let openBody = try body(
            from: "+ (SecKeychainRef)dedicatedKeychainForPath:(NSString *)path\n                          bootstrapService:",
            until: "\n+ (BOOL)deleteBootstrapPasswordForService:",
            in: keychain
        )

        // Everything after the attempt counter is a real open in progress, so
        // every exit from there must record the backoff. A bare `return NULL`
        // means the next of the thousands of lookups one body pass can issue
        // redoes the whole securityd handshake from scratch.
        let counter = try #require(
            openBody.range(of: "[self keychainOpenAttempts]"),
            "The open-attempt counter moved; this guard can no longer tell a served-from-backoff return from a real failure."
        )
        #expect(
            !openBody[counter.upperBound...].contains("return NULL;"),
            """
            dedicatedKeychainForPath: has an uncached failure return. Use \
            noteKeychainUnavailableAtPath:bootstrapService:stage:status: so a burst of \
            failing credential reads costs one open attempt, not one per read.
            """
        )
        #expect(openBody.contains("noteKeychainUnavailableAtPath:"))

        // The bootstrap-password stage must report what securityd actually said.
        // It used to pass a hardcoded `errSecItemNotFound` because
        // `bootstrapPasswordForService:create:` had no status channel — its own
        // read status was captured into a local and never read. That made the
        // one log line that exists say "no such item" for an item that is
        // present but unreadable by this binary, which is the difference between
        // "re-provision the keychain" and "this ad-hoc rebuild is not in the ACL
        // partition list". Exactly the defect the reporting was added to remove.
        #expect(
            openBody.contains("status:&bootstrapStatus"),
            "dedicatedKeychainForPath: stopped asking for the real bootstrap-password status."
        )
        #expect(
            openBody.contains("bootstrapStatus != errSecSuccess"),
            "dedicatedKeychainForPath: reports a placeholder status instead of the measured one."
        )

        // Recovery moves the keychain aside and drops its bootstrap password.
        // That is safe from a write, which repopulates what it was storing, and
        // is silent credential loss from a read, which has nothing to put back.
        let readBody = try body(
            from: "+ (nullable NSString *)secretForAccount:",
            until: "\n+ (",
            in: keychain
        )
        #expect(
            !readBody.contains("recoverUnreadableDedicatedKeychainAtPath:"),
            "The read path must never trigger keychain recovery; it would destroy every stored secret to satisfy a lookup."
        )

        // And on the write path, where recovery IS reachable, the gate must be a
        // probe of the keychain file rather than a reading of the recorded
        // OSStatus.
        //
        // Those describe different objects. The status comes from looking up the
        // bootstrap password in the *login* keychain, so `errSecItemNotFound`
        // means the password is missing — the keychain itself can be sitting
        // there intact and full of credentials. It is also read out of the
        // backoff map, written by whichever attempt last failed at whichever
        // stage, so it is a record of an earlier event and not a measurement of
        // the condition now. Gating destruction on it is how
        // `~/Library/Keychains` came to hold 25 `astra.keychain-db.unreadable-*`
        // files, each encrypted with a password that was deleted first.
        let gateBody = try body(
            from: "+ (BOOL)dedicatedKeychainIsBeyondRecoveryAtPath:",
            until: "\n+ (",
            in: keychain
        )
        #expect(
            gateBody.contains("SecKeychainGetStatus"),
            """
            The recovery gate stopped asking securityd to read the file. \
            SecKeychainOpen alone succeeds lazily against a path holding \
            anything at all, so without GetStatus the gate cannot tell a real \
            keychain from a text file.
            """
        )
        #expect(
            !gateBody.contains("lastFailureStatusForKeychainPath"),
            """
            The recovery gate is deciding whether to destroy the user's keychain \
            from the bootstrap item's status. Probe the keychain file instead.
            """
        )

        // Every OSStatus the gate sees has to be classified. `SecKeychainOpen`
        // fails for a locked keychain, for an ACL denial, and for a securityd
        // that is not answering — each of those a full keychain — so an
        // unconditional YES on a failing open aims the destructive path at
        // precisely the cases it exists to spare. Only "the file is not there"
        // may take that exit.
        #expect(
            gateBody.components(separatedBy: "return YES;").count == 2,
            """
            The recovery gate has more than one unconditional YES. A failing \
            OSStatus is not by itself evidence that there is nothing to lose.
            """
        )
        #expect(
            gateBody.components(separatedBy: "keychainStatusIsBeyondRecovery:").count == 3,
            """
            Both the open status and the status read back from securityd must go \
            through the classifier before recovery is allowed to run.
            """
        )
        let classifier = try body(
            from: "+ (BOOL)keychainStatusIsBeyondRecovery:",
            until: "\n+ (",
            in: keychain
        )
        for tolerated in ["errSecAuthFailed", "errSecInteractionNotAllowed", "errSecNotAvailable"] {
            #expect(
                !classifier.contains(tolerated),
                """
                \(tolerated) describes the machine or this process's \
                authorization, not the file. A keychain that reports it is \
                indistinguishable from a healthy one the user still needs.
                """
            )
        }

        let writeBody = try body(
            from: "+ (BOOL)writeSecret:",
            until: "\n+ (",
            in: keychain
        )
        let recovery = try #require(
            writeBody.range(of: "recoverUnreadableDedicatedKeychainAtPath:"),
            "The write path no longer calls recovery; this guard is scanning for something that moved."
        )
        #expect(
            writeBody[..<recovery.lowerBound].contains("dedicatedKeychainIsBeyondRecoveryAtPath:"),
            "writeSecret: reaches keychain recovery without first proving the keychain is beyond recovery."
        )
    }

    @Test("A count query that fails leaves the credential purge unfinished")
    func failedCountQueriesDoNotCompleteThePurge() throws {
        let source = try fileText("Astra/Services/Persistence/PersistedCredentialPurgeService.swift")
        let purgeBody = try body(
            from: "static func purge(",
            until: "\n    static func liveCredentialValues(",
            in: source
        )

        // The sweep's two count queries are the cheap path: on a clean store
        // they are the only queries a secret costs. That makes them the easiest
        // place to lose the distinction between "this table holds none of this
        // secret" and "this table could not be read". A count coerced to zero
        // skips the rewrite, the loop finishes, `completed` goes true, and
        // `purgeIfNeeded` stamps the build gate — retiring the sweep forever on
        // the strength of a query that never ran. So each count must be a
        // `guard let try?` that returns with `completed` still false.
        var searchStart = purgeBody.startIndex
        var countSites: [Range<String.Index>] = []
        while let site = purgeBody.range(
            of: "modelContext.fetchCount(",
            range: searchStart..<purgeBody.endIndex
        ) {
            countSites.append(site)
            searchStart = site.upperBound
        }
        #expect(
            countSites.count == 2,
            "purge no longer counts events and runs separately; this guard is scanning for something that moved."
        )
        for site in countSites {
            #expect(
                String(purgeBody[..<site.lowerBound].suffix(60)).contains("guard let"),
                """
                A count in purge is not bound by `guard let`. A count that throws \
                is not a count of zero, and the difference is whether the sweep \
                reports success over a table it never queried.
                """
            )
        }
        #expect(
            !purgeBody.contains("?? 0"),
            "purge coerces a failed query to zero. That is the failure this sweep exists to not have."
        )

        // Each failed count must also say so and stop. `continue` would move to
        // the next secret and still finish the loop, which reaches
        // `completed = true` by another road.
        for stage in ["event_count_failed", "run_count_failed"] {
            let branch = try body(from: "\(stage)\"", until: "\n            if ", in: purgeBody)
            #expect(
                branch.prefix(200).contains("return outcome"),
                "The \(stage) branch does not end the sweep; a failed count must leave `completed` false."
            )
        }

        let completion = try #require(
            purgeBody.range(of: "outcome.completed = true"),
            "purge no longer marks its own completion; this guard cannot tell which paths reach it."
        )
        for site in countSites {
            #expect(
                site.upperBound < completion.lowerBound,
                "A count query now runs after the sweep has declared itself complete."
            )
        }
    }

    @Test("An inventory the sweep could not build does not count as an empty one")
    func failedInventoryFetchesDoNotCompleteThePurge() throws {
        let source = try fileText("Astra/Services/Persistence/PersistedCredentialPurgeService.swift")
        let inventoryBody = try body(
            from: "static func liveCredentialValues(",
            until: "\n    private static func eventDescriptor(",
            in: source
        )

        // The inventory decides what the sweep will even look for, so a fetch
        // coerced to `[]` here is worse than a failed count: the sweep does not
        // stop, it searches for a shorter list and finishes clean. Connectors
        // read and skills not is the dangerous shape — `skippedNoSecrets` never
        // fires, `completed` goes true, and `purgeIfNeeded` spends the build
        // gate, so the skill credentials are never searched for again.
        #expect(
            !inventoryBody.contains("try?"),
            """
            liveCredentialValues swallows a fetch failure. A partial inventory \
            still produces a sweep that reports success, which retires the \
            search for whatever it could not enumerate.
            """
        )
        #expect(
            inventoryBody.contains("try modelContext.fetch(FetchDescriptor<Connector>())")
                && inventoryBody.contains("try modelContext.fetch(FetchDescriptor<Skill>())"),
            "The inventory no longer enumerates both credential sources by throwing fetch."
        )

        let purgeBody = try body(
            from: "static func purge(",
            until: "\n    /// Every credential value reachable",
            in: source
        )
        let inventorySite = try #require(
            purgeBody.range(of: "liveCredentialValues("),
            "purge no longer builds an inventory; this guard is scanning for something that moved."
        )
        #expect(
            String(purgeBody[..<inventorySite.lowerBound].suffix(80)).contains("guard let"),
            "purge does not bind the inventory with `guard let`, so a failure to build one looks empty."
        )
        let completion = try #require(purgeBody.range(of: "outcome.completed = true"))
        #expect(
            inventorySite.upperBound < completion.lowerBound,
            "The inventory is built after the sweep has already declared itself complete."
        )
    }

    @Test("An install rollback restores without re-asking admission, and reports a restore it could not make")
    func credentialRollbackDoesNotReRunAdmission() throws {
        let source = try fileText("Astra/Services/Capabilities/CapabilityInstaller.swift")
        let saveBody = try body(
            from: "private func saveConnectorCredentials(",
            until: "\n    private func connectorConfigKeys(",
            in: source
        )
        let rollback = try body(
            from: "guard outcome.isSaved else {",
            until: "savedThisCall.append(",
            in: saveBody
        )

        // Admission decides whether a *new* value may be stored. Asking it
        // again on the way back means the undo can be refused — a tightened
        // package format, a reuse scan that now sees the value elsewhere — and
        // the refusal is pure loss: the prior value is already overwritten, so
        // "no" leaves the failed install's credential in place instead.
        #expect(
            !rollback.contains("connector.saveCredential"),
            """
            The rollback restores through the admission-controlled write again. \
            A value already in the Keychain has been admitted once; re-judging \
            it can only fail the undo.
            """
        )
        #expect(
            rollback.contains("connector.restorePreviouslyStoredCredential("),
            "The rollback no longer restores through the non-admitting path; this guard has lost its subject."
        )
        // Fire-and-forget is the failure mode that matters: a restore that did
        // not land means a credential the user had working is gone, and it is
        // the one thing they cannot discover for themselves.
        #expect(
            rollback.contains("credentialRestoreFailed"),
            "A failed restore is swallowed; the install reports its own failure and not the worse one."
        )
    }

    // MARK: - Helpers

    private func body(
        from declaration: String,
        until terminator: String,
        in source: String
    ) throws -> String {
        let start = try #require(
            source.range(of: declaration),
            "Declaration not found — the guard is scanning for text that no longer exists: \(declaration)"
        )
        let tail = source[start.upperBound...]
        let end = tail.range(of: terminator)?.lowerBound ?? tail.endIndex
        return String(tail[..<end])
    }

    private func fileText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: try repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw CredentialSweepFitnessError.repositoryRootNotFound(FileManager.default.currentDirectoryPath)
            }
            candidate = parent
        }
    }
}

private enum CredentialSweepFitnessError: Error {
    case repositoryRootNotFound(String)
}
