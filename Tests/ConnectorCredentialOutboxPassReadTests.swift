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
// Startup also decodes the mirrors off the main actor before the pass, and
// walks the skill snapshots their tasks carry, which the pass uses only for
// the bytes it reads itself. The workspace deletion pass before it reads
// nothing when no deletion is pending, and the same decodes when one is.

@Suite("Connector credential outbox pass reads", .serialized)
@MainActor
struct ConnectorCredentialOutboxPassReadTests {
    @Test("A pass reads the mirrors as often for three records as for one, and clears and keeps the same records")
    func passReadsOncePerPass() async throws {
        let one = try await mirrorWork(ofPassWithExtraRecords: false)
        let three = try await mirrorWork(ofPassWithExtraRecords: true)
        // The pass's own read of what mirrors list, and one more for both
        // readers of what decides the records.
        #expect(one.reads == 2)
        #expect(three.reads == one.reads)
        // Each read decodes the one mirror's identity. The first then decodes
        // its connectors; the second its connectors once more and, for the
        // other reader, its plugins, skills, and tasks, whose skill
        // snapshots are walked once.
        #expect(one.mainActorDecodes == 5)
        #expect(three.mainActorDecodes == one.mainActorDecodes)
        #expect(one.mainActorWalks == 1)
        #expect(three.mainActorWalks == one.mainActorWalks)
    }

    @Test("A pass given the mirrors decoded ahead decodes none on the main actor, and clears and keeps the same records")
    func passWithDecodesMadeAheadDecodesNothingOnTheMainActor() async throws {
        let onMain = try await mirrorWork(ofPassWithExtraRecords: true)
        let ahead = try await mirrorWork(ofPassWithExtraRecords: true, decodingAhead: true)
        #expect(ahead.reads == onMain.reads)
        #expect(onMain.mainActorDecodes > 0)
        #expect(ahead.mainActorDecodes == 0)
        #expect(onMain.mainActorWalks > 0)
        #expect(ahead.mainActorWalks == 0)
    }

    @Test("A pass with nothing pending reads no mirror, and nothing is decoded ahead for it")
    func emptyOutboxReadsNoMirror() async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))

        let before = CredentialRecoveryMirrors.readCount
        let decodes = CredentialRecoveryMirrors.mainActorDecodeCount
        #expect(await ConnectorCredentialCleanup.decodeMirrorsAhead(modelContext: context, store: outbox, extraMirrors: []) == nil)
        #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox, extraMirrors: []) == 0)
        #expect(CredentialRecoveryMirrors.readCount == before)
        #expect(CredentialRecoveryMirrors.mainActorDecodeCount == decodes)
    }

    @Test("A mirror rewritten after it was decoded ahead is decoded again, and what it lists now is spared")
    func mirrorRewrittenAfterTheDecodeIsReadAsItIsNow() async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let (workspace, mirror) = try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try await withTemporaryOutboxKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://shared.example.invalid")
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])

            let decoded = try #require(await ConnectorCredentialCleanup.decodeMirrorsAhead(
                modelContext: context, store: outbox, extraMirrors: []))
            // Once decoded, the mirror comes to list a connector, never
            // stored, on the deleted one's stable namespace.
            try Data(#"""
                {"id":"\#(workspace.id.uuidString)","connectors":[{"id":"\#(UUID().uuidString)","name":"Jira",
                 "serviceType":"jira","baseURL":"https://shared.example.invalid"}]}
                """#.utf8).write(to: mirror)

            let decodes = CredentialRecoveryMirrors.mainActorDecodeCount
            #expect(ConnectorCredentialCleanup.resumePending(
                modelContext: context, store: outbox, extraMirrors: [], decodedAhead: decoded) == 1)
            #expect(CredentialRecoveryMirrors.mainActorDecodeCount > decodes)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
        }
    }

    @Test("A mirror rewritten after it was decoded ahead to hold the account in a task snapshot keeps the record")
    func mirrorRewrittenWithATaskHoldingTheAccountKeepsTheRecord() async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let (workspace, mirror) = try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try await withTemporaryOutboxKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://plain.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])

            let decoded = try #require(await ConnectorCredentialCleanup.decodeMirrorsAhead(
                modelContext: context, store: outbox, extraMirrors: []))
            // Once decoded, the mirror comes to hold a task whose skill
            // snapshot names the deleted account. Only the request reader
            // reads tasks; the connectors it lists stay none.
            let snapshot = SkillSnapshotConfig(
                id: nil, name: "Reports", icon: "", description: "", allowedTools: [], disallowedTools: [], customTools: [],
                behaviorInstructions: "", environmentKeys: [], environmentValues: [], isGlobal: nil,
                connectorIDs: [deleted.id.uuidString], localToolIDs: nil, connectorSnapshots: nil, localToolSnapshots: nil,
                createdAt: nil, updatedAt: nil)
            let snapshotJSON = try #require(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8))
            try Data(#"{"id":"\#(workspace.id.uuidString)","connectors":[],"tasks":[{"skillSnapshots":[\#(snapshotJSON)]}]}"#.utf8)
                .write(to: mirror)

            let decodes = CredentialRecoveryMirrors.mainActorDecodeCount
            let walks = PluginCredentialMirrorReferences.mainActorSnapshotWalkCount
            #expect(ConnectorCredentialCleanup.resumePending(
                modelContext: context, store: outbox, extraMirrors: [], decodedAhead: decoded) == 0)
            #expect(CredentialRecoveryMirrors.mainActorDecodeCount > decodes)
            #expect(PluginCredentialMirrorReferences.mainActorSnapshotWalkCount > walks)
            #expect(outbox.pending()?.records.map(\.cleanup) == [deleted.keychainCleanup])
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            // Kept because the rewritten mirror holds the account, not
            // because a reader failed.
            #expect(PluginCredentialMirrorReferences.capture(modelContext: context, extraMirrors: [])?
                .holdsAccount(deleted.keychainCleanup) == true)
        }
    }

    @Test("A mirror that doesn't decode stops the pass, whether or not it was decoded ahead", arguments: [false, true])
    func undecodableMirrorStopsThePass(decodingAhead: Bool) async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let (_, mirror) = try storeWorkspace(withMirrorUnder: root, in: context)
        try Data(#"{"id":"#.utf8).write(to: mirror)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try await withTemporaryOutboxKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://plain.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])
            var decoded: CredentialMirrorDecodes?
            if decodingAhead {
                decoded = await ConnectorCredentialCleanup.decodeMirrorsAhead(modelContext: context, store: outbox, extraMirrors: [])
                #expect(decoded != nil)
            }

            #expect(ConnectorCredentialCleanup.resumePending(
                modelContext: context, store: outbox, extraMirrors: [], decodedAhead: decoded) == 0)
            #expect(outbox.pending()?.records.map(\.cleanup) == [deleted.keychainCleanup])
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
        }
    }

    @Test("A task's skill snapshot in a mirror holds its account, whether walked ahead or on the main actor",
          arguments: [false, true])
    func taskSkillSnapshotHoldsItsAccount(decodingAhead: Bool) async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let (workspace, mirror) = try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try await withTemporaryOutboxKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://plain.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            try writeMirror(mirror, of: workspace, withTaskSnapshotConnectorIDs: [deleted.id.uuidString])
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])
            var decoded: CredentialMirrorDecodes?
            if decodingAhead {
                decoded = await ConnectorCredentialCleanup.decodeMirrorsAhead(modelContext: context, store: outbox, extraMirrors: [])
                #expect(decoded != nil)
            }

            let decodes = CredentialRecoveryMirrors.mainActorDecodeCount
            let walks = PluginCredentialMirrorReferences.mainActorSnapshotWalkCount
            #expect(ConnectorCredentialCleanup.resumePending(
                modelContext: context, store: outbox, extraMirrors: [], decodedAhead: decoded) == 0)
            #expect(outbox.pending()?.records.map(\.cleanup) == [deleted.keychainCleanup])
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect((CredentialRecoveryMirrors.mainActorDecodeCount == decodes) == decodingAhead)
            #expect((PluginCredentialMirrorReferences.mainActorSnapshotWalkCount == walks) == decodingAhead)
        }
    }

    @Test("A skill snapshot naming an ID that isn't one stops the pass, whether walked ahead or on the main actor",
          arguments: [false, true])
    func malformedTaskSkillSnapshotStopsThePass(decodingAhead: Bool) async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let (workspace, mirror) = try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try await withTemporaryOutboxKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://plain.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            try writeMirror(mirror, of: workspace, withTaskSnapshotConnectorIDs: ["not-an-account-id"])
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])
            var decoded: CredentialMirrorDecodes?
            if decodingAhead {
                decoded = try #require(await ConnectorCredentialCleanup.decodeMirrorsAhead(
                    modelContext: context, store: outbox, extraMirrors: []))
            }

            #expect(ConnectorCredentialCleanup.resumePending(
                modelContext: context, store: outbox, extraMirrors: [], decodedAhead: decoded) == 0)
            #expect(outbox.pending()?.records.map(\.cleanup) == [deleted.keychainCleanup])
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(PluginCredentialMirrorReferences.capture(modelContext: context, extraMirrors: [], decodedAhead: decoded) == nil)
        }
    }

    @Test("A workspace deletion pass with nothing pending reads no mirror, and nothing is decoded ahead for it")
    func emptyDeletionOutboxReadsNoMirror() async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try storeWorkspace(withMirrorUnder: root, in: context)
        let deletions = WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("Deletions"))
        let connectors = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))

        let before = CredentialRecoveryMirrors.readCount
        #expect(await WorkspaceDeletionCleanupService.decodeMirrorsAhead(
            modelContext: context, store: deletions, extraMirrors: []) == nil)
        #expect(WorkspaceDeletionCleanupService.resumePending(
            modelContext: context, store: deletions, connectorOutbox: connectors, extraMirrors: []) == 0)
        #expect(CredentialRecoveryMirrors.readCount == before)
    }

    @Test("A workspace deletion pass given the mirrors decoded ahead settles the same, decoding nothing on the main actor",
          arguments: [false, true])
    func deletionPassWithDecodesMadeAhead(decodingAhead: Bool) async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let (workspace, mirror) = try storeWorkspace(withMirrorUnder: root, in: context)
        let deletions = WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("Deletions"))
        let connectors = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try await withTemporaryOutboxKeychain {
            // The deleted workspace's connector goes; one a surviving
            // workspace's task snapshot names stays.
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://gone.example.invalid")
            let held = Connector(name: "Jira", serviceType: "jira", baseURL: "https://held.example.invalid")
            let deletedOwn = KeychainSecretStore.connectorEntityID(for: deleted.id)
            let heldOwn = KeychainSecretStore.connectorEntityID(for: held.id)
            for service in [deletedOwn, heldOwn] {
                #expect(AstraSecureKeychainStore.save(service: service, account: "TOKEN", value: "value", label: nil))
            }
            try writeMirror(mirror, of: workspace, withTaskSnapshotConnectorIDs: [held.id.uuidString])
            let record = WorkspaceDeletionCleanupRecord(
                workspaceID: UUID(), primaryPath: root.appendingPathComponent("Deleted").path,
                connectors: [deleted.keychainCleanup, held.keychainCleanup], skills: [])
            try deletions.write(record)
            try deletions.markCommitted(record)
            let decoded = await WorkspaceDeletionCleanupService.decodeMirrorsAhead(
                modelContext: context, store: deletions, extraMirrors: [])
            #expect(decoded != nil)

            let decodes = CredentialRecoveryMirrors.mainActorDecodeCount
            let walks = PluginCredentialMirrorReferences.mainActorSnapshotWalkCount
            // The record stays: a credential it names is still held.
            #expect(WorkspaceDeletionCleanupService.resumePending(
                modelContext: context, store: deletions, connectorOutbox: connectors, extraMirrors: [],
                decodedAhead: decodingAhead ? decoded : nil) == 0)
            #expect(deletions.pending() == [record])
            #expect(AstraSecureKeychainStore.load(service: deletedOwn, account: "TOKEN") == nil)
            #expect(AstraSecureKeychainStore.load(service: heldOwn, account: "TOKEN") == "value")
            #expect((CredentialRecoveryMirrors.mainActorDecodeCount == decodes) == decodingAhead)
            #expect((PluginCredentialMirrorReferences.mainActorSnapshotWalkCount == walks) == decodingAhead)
        }
    }

    /// Rewrites `mirror` to list no connector and one task whose skill
    /// snapshot names `connectorIDs`.
    private func writeMirror(_ mirror: URL, of workspace: Workspace, withTaskSnapshotConnectorIDs connectorIDs: [String]) throws {
        let snapshot = SkillSnapshotConfig(
            id: nil, name: "Reports", icon: "", description: "", allowedTools: [], disallowedTools: [], customTools: [],
            behaviorInstructions: "", environmentKeys: [], environmentValues: [], isGlobal: nil,
            connectorIDs: connectorIDs, localToolIDs: nil, connectorSnapshots: nil, localToolSnapshots: nil,
            createdAt: nil, updatedAt: nil)
        let snapshotJSON = try #require(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8))
        try Data(#"{"id":"\#(workspace.id.uuidString)","connectors":[],"tasks":[{"skillSnapshots":[\#(snapshotJSON)]}]}"#.utf8)
            .write(to: mirror)
    }

    /// Runs one `resumePending` over a plain deleted connector and, with
    /// `extraRecords`, one whose stable namespace a live connector still
    /// reads and one whose ownership this build can't resolve, its mirrors
    /// decoded ahead when `decodingAhead`. Checks what each record's run did
    /// and returns how many mirror reads, and decodes and snapshot walks on
    /// the main actor, the pass made.
    private func mirrorWork(
        ofPassWithExtraRecords extraRecords: Bool, decodingAhead: Bool = false
    ) async throws -> (reads: Int, mainActorDecodes: Int, mainActorWalks: Int) {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-outbox-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try storeWorkspace(withMirrorUnder: root, in: context)
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        return try await withTemporaryOutboxKeychain {
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
            var decoded: CredentialMirrorDecodes?
            if decodingAhead {
                decoded = try #require(await ConnectorCredentialCleanup.decodeMirrorsAhead(
                    modelContext: context, store: outbox, extraMirrors: []))
            }

            let before = CredentialRecoveryMirrors.readCount
            let decodes = CredentialRecoveryMirrors.mainActorDecodeCount
            let walks = PluginCredentialMirrorReferences.mainActorSnapshotWalkCount
            let cleared = ConnectorCredentialCleanup.resumePending(
                modelContext: context, store: outbox, extraMirrors: [], decodedAhead: decoded)
            let work = (reads: CredentialRecoveryMirrors.readCount - before,
                        mainActorDecodes: CredentialRecoveryMirrors.mainActorDecodeCount - decodes,
                        mainActorWalks: PluginCredentialMirrorReferences.mainActorSnapshotWalkCount - walks)

            #expect(cleared == cleanups.count - held.count)
            #expect(outbox.pending()?.records.map(\.cleanup) == held)
            #expect(AstraSecureKeychainStore.load(service: plainOwn, account: "TOKEN") == nil)
            if let shared {
                #expect(AstraSecureKeychainStore.load(service: shared.own, account: "TOKEN") == nil)
                #expect(KeychainService.load(key: "TOKEN", connector: shared.live) == "shared")
            }
            return work
        }
    }

    /// A stored workspace with a mirror on disk, which every pass reads.
    @discardableResult
    private func storeWorkspace(withMirrorUnder root: URL, in context: ModelContext) throws -> (Workspace, URL) {
        let folder = root.appendingPathComponent("App", isDirectory: true)
        let workspace = Workspace(name: "App", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id":"\#(workspace.id.uuidString)","connectors":[]}"#.utf8).write(to: mirror)
        return (workspace, mirror)
    }

    /// A temporary dedicated keychain, through task-locals only, so nothing
    /// here reaches the developer's real Keychain.
    private func withTemporaryOutboxKeychain<T>(_ body: () async throws -> T) async rethrows -> T {
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: []) }
        return try await AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try await AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) { try await body() }
        }
    }
}
