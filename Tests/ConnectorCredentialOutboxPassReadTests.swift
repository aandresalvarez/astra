import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence

// Startup's connector outbox pass judges every pending record against one
// read of what decides it. Each read decodes every workspace mirror on the
// main actor, so reading again for each record froze launch for seconds.

@Suite("Connector credential outbox pass reads", .serialized)
@MainActor
struct ConnectorCredentialOutboxPassReadTests {
    @Test("A pass reads the mirrors as often for three records as for one, and clears and keeps the same records")
    func passReadsOncePerPass() throws {
        let one = try mirrorReads(ofPassWithExtraRecords: false)
        let three = try mirrorReads(ofPassWithExtraRecords: true)
        #expect(one > 0)
        #expect(three == one)
    }

    @Test("A pass with nothing pending reads no mirror")
    func emptyOutboxReadsNoMirror() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))

        let before = CredentialRecoveryMirrors.readCount
        #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox, extraMirrors: []) == 0)
        #expect(CredentialRecoveryMirrors.readCount == before)
    }

    /// Runs one `resumePending` over a plain deleted connector and, with
    /// `extraRecords`, one whose stable namespace a live connector still
    /// reads and one whose ownership this build can't resolve. Checks what
    /// each record's run did and returns how many mirror reads the pass made.
    private func mirrorReads(ofPassWithExtraRecords extraRecords: Bool) throws -> Int {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        return try withTemporaryOutboxKeychain {
            let plain = Connector(name: "Jira", serviceType: "jira", baseURL: "https://plain.example.invalid")
            let plainOwn = KeychainSecretStore.connectorEntityID(for: plain.id)
            #expect(AstraSecureKeychainStore.save(service: plainOwn, account: "TOKEN", value: "plain", label: nil))
            var cleanups = [plain.keychainCleanup]
            var shared: (own: String, live: Connector)?
            var held: [ConnectorKeychainCleanup] = []
            if extraRecords {
                let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://shared.example.invalid")
                let live = Connector(name: "Jira", serviceType: "jira", baseURL: "https://shared.example.invalid")
                context.insert(live)
                let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
                let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
                #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
                #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
                shared = (own, live)
                // Outlook ownership in a format this build can't resolve is
                // never deleted: its record waits.
                let unresolved = try JSONDecoder().decode(ConnectorKeychainCleanup.self, from: Data("""
                    {"connectorID":"\(UUID().uuidString)","name":"Mail","serviceType":"\(OutlookCredentialIdentity.serviceType)",
                     "baseURL":"","isStanfordOutlookMail":false,"outlookCredentialFormat":"unknown-format"}
                    """.utf8))
                held = [unresolved]
                cleanups += [deleted.keychainCleanup, unresolved]
            }
            try context.save()
            _ = try outbox.record(cleanups, storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted(cleanups)

            let before = CredentialRecoveryMirrors.readCount
            let cleared = ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox, extraMirrors: [])
            let reads = CredentialRecoveryMirrors.readCount - before

            #expect(cleared == cleanups.count - held.count)
            #expect(outbox.pending()?.records.map(\.cleanup) == held)
            #expect(AstraSecureKeychainStore.load(service: plainOwn, account: "TOKEN") == nil)
            if let shared {
                #expect(AstraSecureKeychainStore.load(service: shared.own, account: "TOKEN") == nil)
                #expect(KeychainService.load(key: "TOKEN", connector: shared.live) == "shared")
            }
            return reads
        }
    }

    /// A stored workspace with a mirror on disk, which every pass reads.
    private func storeWorkspace(withMirrorUnder root: URL, in context: ModelContext) throws {
        let folder = root.appendingPathComponent("App", isDirectory: true)
        let workspace = Workspace(name: "App", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id":"\#(workspace.id.uuidString)","connectors":[]}"#.utf8).write(to: mirror)
    }

    /// A temporary dedicated keychain, through task-locals only, so nothing
    /// here reaches the developer's real Keychain.
    private func withTemporaryOutboxKeychain<T>(_ body: () throws -> T) rethrows -> T {
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: []) }
        return try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) { try body() }
        }
    }
}
