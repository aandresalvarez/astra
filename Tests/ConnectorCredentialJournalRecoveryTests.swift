import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Synthetic stores and journals. End-to-end writes use the test-only private
/// vault; recovery itself must preserve every credential and account row.
@MainActor
@Suite("Account credential journal recovery", .serialized)
struct ConnectorCredentialJournalRecoveryTests {
    @Test("Legacy journals require exact ownership before collecting", arguments: ["same", "device", "inode", "path"])
    func journalValidationDimensions(difference: String) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let identity = try #require(PersistentStoreIdentity.current(for: env.context))
        let recorded = changed(identity, dimension: difference)
        try writeJournal(journal, identity: recorded)
        if difference == "same" { #expect(try journal.pending().isEmpty) }
        else { expectWrongStore { _ = try journal.pending() } }
    }

    @Test("Device-only drift blocks full re-entry before vault or model writes", arguments: [false, true])
    func fullReentryCannotBypassJournal(generatedAccount: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env, generated: generatedAccount)
        let priorNamespace = account.credentialNamespaceID
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let identity = try #require(PersistentStoreIdentity.current(for: env.context))
        try writeJournal(journal, identity: changed(identity, dimension: "device"))
        let before = try Data(contentsOf: journal.fileURL)
        let vault = RefusingVault()
        #expect(ConnectorCredentialEditor.unreadableKeys(of: account, vault: vault) == ["JIRA_API_TOKEN", "JIRA_EMAIL"])
        let reads = vault.reads
        var persistCalled = false
        expectWrongStore {
            _ = try ConnectorCredentialEditor.save(
                ["JIRA_EMAIL": "synthetic@example.test", "JIRA_API_TOKEN": "synthetic-incident-token"],
                on: account, modelContext: env.context,
                persist: { _ in persistCalled = true }, rewriteMirror: { _ in true }, vault: vault)
        }
        #expect(vault.reads == reads && vault.writes == 0)
        #expect(!persistCalled && !env.context.hasChanges)
        #expect(account.credentialNamespaceID == priorNamespace)
        #expect(try Data(contentsOf: journal.fileURL) == before)
    }

    @Test("A matching journal admits preparation when every unreadable key is replaced")
    func matchingJournalAdmitsCompleteReplacement() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: #require(PersistentStoreIdentity.current(for: env.context)))
        let vault = RefusingVault()
        let keys = Set(account.credentialKeys)
        let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
            keeping: keys, replacing: keys, modelContext: env.context, legacyHandling: .preservePending, vault: vault)
        #expect(vault.reads == 0 && vault.writes == 0)
        #expect(try journal.pending().count == 2)
        #expect(account.credentialNamespaceID == nil && !env.context.hasChanges)
        prepared.discard()
    }

    @Test("Explicit journal recovery lets migration defer only the unreadable account")
    func recoveryUnblocksMigrationReentryDeferral() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        var package = env.package
        package.connectors = [PluginConnector(name: "Synthetic Jira", serviceType: "jira", icon: "network",
            description: "Synthetic incident investigation", baseURL: "https://jira.example.test", authMethod: "basic",
            credentialHints: [.init(key: "JIRA_EMAIL", hint: "Email"), .init(key: "JIRA_API_TOKEN", hint: "Token")],
            configHints: [], notes: "")]
        let account = try makeAccount(in: env)
        CapabilityResourceOrigin.stamp(account, package: package,
            componentID: CapabilityResourceOrigin.componentID(for: package.connectors[0]))
        env.workspace.legacyInstalledPluginIDs = [package.id]
        env.workspace.legacyInstalledPluginVersions = [package.version]
        env.workspace.legacyEnabledCapabilityIDs = [package.id]
        try env.context.save()
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let identity = try #require(PersistentStoreIdentity.current(for: env.context))
        try writeJournal(journal, identity: changed(identity, dimension: "device"))
        let vault = RefusingVault()
        expectWrongStore {
            _ = try PluginActivationMigration.migrate(modelContext: env.context, packages: [package],
                sourceStore: PluginSourceStore(root: env.disk.root.appendingPathComponent("Sources")),
                rewriteMirror: { _ in true }, vault: vault)
        }
        #expect(vault.reads == 0 && vault.writes == 0)
        #expect(env.workspace.legacyEnabledCapabilityIDs == [package.id])
        #expect(account.credentialNamespaceID == nil)
        // The startup context stays usable: recovery must not require a restart
        // or a compensating save of fields restored by failed migration.
        #expect(!env.context.hasChanges)
        try ConnectorCredentialEditor.recoverJournal(on: account, modelContext: env.context)
        let report = try PluginActivationMigration.migrate(modelContext: env.context, packages: [package],
            sourceStore: PluginSourceStore(root: env.disk.root.appendingPathComponent("Sources")),
            rewriteMirror: { _ in true }, vault: vault)
        #expect(report.accountsAwaitingReentry[account.id] == "JIRA_API_TOKEN")
        #expect(report.accountsBound == 1)
        #expect(account.credentialNamespaceID == nil && vault.writes == 0)
    }

    @Test("Background recovery preserves an unverifiable journal until an explicit action")
    func recoveryDoesNotRebindJournal() async throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        let identity = try #require(PersistentStoreIdentity.current(for: env.context))
        try writeJournal(journal, identity: changed(identity, dimension: "device"))
        let before = try Data(contentsOf: journal.fileURL)
        #expect(ConnectorCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.context))
        #expect(journal.resumePending(modelContext: env.context) == 0)
        ConnectorCredentialGenerationJournal.resumeAfterWorkspaceRecovery(modelContext: env.context)
        await ConnectorCredentialGenerationJournal.resumeAfterWorkspaceRecoveryAsync(modelContext: env.context)
        #expect(try Data(contentsOf: journal.fileURL) == before)
        expectWrongStore { _ = try journal.pending() }
    }

    @Test("Explicit recovery preserves legacy candidates, then full Jira re-entry commits and reopens")
    func recoverThenReenterJira() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let account = try makeAccount(in: env)
            let oldSlot = KeychainSecretStore.connectorEntityID(for: account.id)
            for (key, value) in ["JIRA_EMAIL": "old@example.test", "JIRA_API_TOKEN": "synthetic-old-token"] {
                try #require(AstraSecureKeychainStore.save(service: oldSlot, account: key, value: value, label: nil))
            }
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
            let oldIdentity = changed(try #require(PersistentStoreIdentity.current(for: env.context)), dimension: "device")
            let original = account.keychainCleanup
            try writeJournal(journal, identity: oldIdentity, candidates: [original])
            let before = try Data(contentsOf: journal.fileURL)
            let vault = PluginMigrationUnreadableCredentialTests.RefusingVault(refused: Set(KeychainSecretStore.connectorEntityIDs(for: account)))
            #expect(ConnectorCredentialEditor.unreadableKeys(of: account, vault: vault).count == 2)
            #expect(ConnectorCredentialEditor.canRecoverJournal(modelContext: env.context))

            try ConnectorCredentialEditor.recoverJournal(on: account, modelContext: env.context)
            #expect(!env.context.hasChanges && account.credentialNamespaceID == nil)
            #expect(!ConnectorCredentialEditor.canRecoverJournal(modelContext: env.context))
            #expect(try journal.pending().isEmpty)
            let archived = try #require(try recoveryArchives(journal).first)
            #expect(try Data(contentsOf: archived) == before)
            #expect(AstraSecureKeychainStore.read(service: oldSlot, account: "JIRA_API_TOKEN") == .value("synthetic-old-token"))

            let failure = try ConnectorCredentialEditor.save(["JIRA_EMAIL": "new@example.test", "JIRA_API_TOKEN": "synthetic-new-token"],
                on: account, modelContext: env.context, rewriteMirror: { _ in true }, vault: vault)
            #expect(failure == nil)
            let namespace = try #require(account.credentialNamespaceID)
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first { $0.id == account.id })
            #expect(saved.credentialNamespaceID == namespace)
            #expect(saved.currentCredentialValue(forKey: "JIRA_EMAIL") == "new@example.test")
            #expect(saved.currentCredentialValue(forKey: "JIRA_API_TOKEN") == "synthetic-new-token")
            _ = journal.resumePending(modelContext: env.context, extraMirrors: [], rewriteMirror: { _, _ in true })
            #expect(ConnectorCredentialCleanup.run([original], modelContext: env.context, extraMirrors: []))
            let deletion = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: env.disk.root.appendingPathComponent("deleted").path,
                connectors: [original], skills: [])
            #expect(WorkspaceDeletionCleanupService.settle(deletion, modelContext: env.context, extraMirrors: []))
            #expect(AstraSecureKeychainStore.read(service: oldSlot, account: "JIRA_API_TOKEN") == .value("synthetic-old-token"))
            let reopenedJournal = try #require(try ConnectorCredentialGenerationJournal(modelContext: reopened.mainContext))
            _ = try reopenedJournal.pending()
            #expect(!reopenedJournal.canRecoverEditing())
            #expect(try Data(contentsOf: archived) == before)
            let contents = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as? [String: Any])
            #expect(contents["version"] as? Int == 2)
            #expect(contents["recovery"] != nil)
        }
    }

    @Test("A matching legacy record upgrades without losing any candidates")
    func matchingLegacyUpgrade() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: #require(PersistentStoreIdentity.current(for: env.context)), candidates: [account.keychainCleanup])
        let lease = try journal.acquireLease()
        try journal.record([], lease: lease)
        #expect(try journal.pending() == [account.keychainCleanup])
        let contents = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as? [String: Any])
        #expect(contents["version"] as? Int == 2)
        #expect(contents["storeIdentity"] as? String == PersistentStoreIdentity.credentialJournal(for: env.context))
        #expect(try recoveryArchives(journal).isEmpty)
    }

    @Test("Interrupted publication retains the original and retries the same immutable archive")
    func failedPublicationRetries() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: "/synthetic/other.store|1:1", candidates: [account.keychainCleanup])
        let before = try Data(contentsOf: journal.fileURL)
        let lease = try journal.acquireLease()
        #expect(throws: CocoaError.self) {
            try journal.recoverEditing(lease: lease, publish: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(try Data(contentsOf: journal.fileURL) == before)
        #expect(journal.canRecoverEditing())
        #expect(try recoveryArchives(journal).count == 1)
        let receipt = try #require(try journal.recoverEditing(lease: lease))
        #expect(try recoveryArchives(journal).count == 1)
        let recovered = try Data(contentsOf: journal.fileURL)
        #expect(try journal.recoverEditing(lease: lease) == nil)
        #expect(try Data(contentsOf: journal.fileURL) == recovered)
        #expect(try Data(contentsOf: recoveryArchives(journal)[0]) == before)
        #expect(receipt.previousVersion == 1)
        #expect(try journal.pending().isEmpty)
        #expect(journal.resumePending(modelContext: env.context) == 0)
    }

    @Test("A failed archive sync must be retried even when the complete archive already exists")
    func failedArchiveSyncRetries() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: "/synthetic/other.store|1:1")
        let before = try Data(contentsOf: journal.fileURL)
        let lease = try journal.acquireLease()
        var attempts = 0
        for _ in 0..<2 {
            #expect(throws: CocoaError.self) {
                try journal.recoverEditing(lease: lease, synchronizeArchive: { _ in
                    attempts += 1
                    throw CocoaError(.fileWriteUnknown)
                })
            }
            #expect(try Data(contentsOf: journal.fileURL) == before)
            #expect(try recoveryArchives(journal).count == 1)
        }
        #expect(attempts == 2)
        #expect(try journal.recoverEditing(lease: lease) != nil)
        #expect(try journal.pending().isEmpty)
    }

    @Test("Future, malformed, oversized and symlinked journals remain untouched", arguments: ["future", "malformed", "oversized", "symlink"])
    func unsupportedRecordsCannotBeRecovered(kind: String) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        switch kind {
        case "future": try writeJournal(journal, identity: "/synthetic/other.store|1:1", version: 3)
        case "malformed": try Data("malformed".utf8).write(to: journal.fileURL)
        case "oversized": try Data(repeating: 32, count: 1_048_577).write(to: journal.fileURL)
        default:
            let target = env.disk.root.appendingPathComponent("symlink-target")
            try Data("untouched".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: journal.fileURL, withDestinationURL: target)
        }
        let before = try Data(contentsOf: journal.fileURL)
        #expect(!journal.canRecoverEditing())
        let lease = try journal.acquireLease()
        #expect(throws: (any Error).self) { try journal.recoverEditing(lease: lease) }
        #expect(try Data(contentsOf: journal.fileURL) == before)
        #expect(try recoveryArchives(journal).isEmpty)
        if kind == "future" {
            #expect(throws: ConnectorCredentialGenerationJournal.Failure.unsupportedVersion) { _ = try journal.pending() }
        }
    }

    @Test("Pending edits and an active producer block explicit journal recovery", arguments: [false, true])
    func recoveryHonorsMutationBoundaries(pendingEdit: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: "/synthetic/other.store|1:1")
        let before = try Data(contentsOf: journal.fileURL)
        let lease = pendingEdit ? nil : try journal.acquireLease()
        if pendingEdit { account.name = "Unsaved synthetic edit" }
        #expect(throws: (any Error).self) { try ConnectorCredentialEditor.recoverJournal(on: account, modelContext: env.context) }
        #expect(try Data(contentsOf: journal.fileURL) == before)
        #expect(try recoveryArchives(journal).isEmpty)
        #expect(env.context.hasChanges == pendingEdit)
        withExtendedLifetime(lease) {}
    }

    @Test("An unfinished credential operation keeps its original recovery action")
    func pendingOperationCannotBeBypassed() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: "/synthetic/other.store|1:1")
        let before = try Data(contentsOf: journal.fileURL)
        let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: [], workspaceIDs: [], modelContext: env.context)
        guard case .committed(let receipt, _) = outcome else { Issue.record("Fixture receipt did not commit"); return }
        #expect(throws: PluginOperationProblem.self) {
            try ConnectorCredentialEditor.recoverJournal(on: account, modelContext: env.context)
        }
        #expect(try PluginOperationCommit.read(receipt.id, container: env.context.container)?.completedAt == nil)
        #expect(try Data(contentsOf: journal.fileURL) == before)
        #expect(try recoveryArchives(journal).isEmpty)
    }

    @Test("A symlinked archive directory cannot redirect preserved recovery records")
    func archiveDirectoryCannotRedirect() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: "/synthetic/other.store|1:1")
        let before = try Data(contentsOf: journal.fileURL)
        let other = env.disk.root.appendingPathComponent("other-directory")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let directory = journal.fileURL.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialRecovery")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: other)
        let lease = try journal.acquireLease()
        #expect(throws: (any Error).self) { try journal.recoverEditing(lease: lease) }
        #expect(try Data(contentsOf: journal.fileURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test("Repeated recovery retains the complete archive chain; damaged history blocks collectors")
    func recoveryHistoryKeepsOwnership() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = try makeAccount(in: env)
        let original = account.keychainCleanup
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeJournal(journal, identity: "/synthetic/other.store|1:1", candidates: [original])
        let lease = try journal.acquireLease()
        try journal.recoverEditing(lease: lease)
        let firstArchive = try #require(try recoveryArchives(journal).first)
        var second = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as? [String: Any])
        second["storeIdentity"] = "/synthetic/foreign.store|credential-v2:foreign"
        try JSONSerialization.data(withJSONObject: second, options: [.sortedKeys]).write(to: journal.fileURL, options: .atomic)
        #expect(try journal.recoverEditing(lease: lease)?.previousVersion == 2)
        #expect(try recoveryArchives(journal).count == 2)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == [original])
        try Data("damaged archive".utf8).write(to: firstArchive)
        #expect(ConnectorCredentialGenerationJournal.retainedRecoveryCandidates(modelContext: env.context) == nil)
        #expect(ConnectorCredentialCleanup.capturedOwnership(modelContext: env.context, extraMirrors: []) == nil)
        #expect(!ConnectorCredentialCleanup.run([original], modelContext: env.context, extraMirrors: []))
    }

    @Test("Unreadable-secret copy describes Keychain authorization without assuming a prior build")
    func reentryMessageNamesAuthorization() {
        for count in [1, 2] {
            let message = ConnectorCredentialReentrySection.message(keyCount: count, subject: "account")
            #expect(message.contains("Keychain access"))
            #expect(!message.contains("earlier build"))
            if count == 2 { #expect(message.contains("together")) }
        }
    }

    private func recoveryArchives(_ journal: ConnectorCredentialGenerationJournal) throws -> [URL] {
        let directory = journal.fileURL.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialRecovery")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func makeAccount(in env: PluginAddCommitTests.Fixture, generated: Bool = false) throws -> Connector {
        let account = Connector(name: "Synthetic Jira", serviceType: "jira", baseURL: "https://jira.example.test", authMethod: "basic")
        account.isGlobal = true
        account.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        account.credentialValues = ["", ""]
        if generated { account.credentialNamespaceID = UUID() }
        env.context.insert(account)
        try env.context.save()
        return account
    }

    private func changed(_ identity: String, dimension: String) -> String {
        let parts = identity.split(separator: "|")
        let numbers = parts[1].split(separator: ":")
        switch dimension {
        case "device": return "\(parts[0])|\((UInt64(numbers[0]) ?? 0) + 3):\(numbers[1])"
        case "inode": return "\(parts[0])|\(numbers[0]):\((UInt64(numbers[1]) ?? 0) + 1)"
        case "path": return "\(parts[0]).other|\(parts[1])"
        default: return identity
        }
    }

    private func writeJournal(_ journal: ConnectorCredentialGenerationJournal, identity: String, version: Int = 1,
                              candidates: [ConnectorKeychainCleanup] = []) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidates))
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "storeIdentity": identity, "candidates": encoded], options: [.sortedKeys])
        try data.write(to: journal.fileURL, options: .atomic)
    }

    private func expectWrongStore(_ body: () throws -> Void) {
        do { try body(); Issue.record("Expected wrongStore") }
        catch ConnectorCredentialGenerationJournal.Failure.wrongStore { }
        catch { Issue.record("Unexpected error type: \(String(reflecting: type(of: error)))") }
    }

    private final class RefusingVault: SecretStore {
        var reads = 0
        var writes = 0
        func read(key: String, entityID: String) -> SecretReadOutcome { reads += 1; return .unavailable }
        func load(key: String, entityID: String) -> String? { reads += 1; return nil }
        func save(key: String, value: String, entityID: String, label: String?) -> Bool { writes += 1; return false }
        func delete(key: String, entityID: String) -> Bool { Issue.record("Unexpected vault delete"); return false }
        func deleteAll(entityID: String) { Issue.record("Unexpected vault deleteAll") }
        func exists(key: String, entityID: String) -> Bool { false }
    }
}
