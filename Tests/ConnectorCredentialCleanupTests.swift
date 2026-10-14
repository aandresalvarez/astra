import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence
import ASTRACore

// Deleting a connector must never remove a Keychain namespace another stored
// connector still reads: a connector recreated under a new ID shares the old
// one's stable endpoint or package namespace.

private func credentialCleanupContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

/// A temporary dedicated keychain, installed through task-locals only, so
/// these reads and writes never reach the developer's real Keychain.
private func withTemporaryCredentialKeychain<T>(_ body: () throws -> T) rethrows -> T {
    let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
    let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
    AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
    defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: []) }
    return try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
        try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
            try body()
        }
    }
}

private func credentialPackage(id: String) -> PluginPackage {
    var package = PluginPackage(
        id: id, name: id, icon: "link", description: "d",
        author: "a", category: "c", tags: [], version: "1.0.0",
        skills: [],
        connectors: [PluginConnector(
            name: "\(id) Connector", serviceType: "svc-\(id)", icon: "link",
            description: "d", baseURL: "https://\(id).example.com", authMethod: "api_key",
            credentialHints: [.init(key: "SVC_TOKEN", hint: "h")],
            configHints: [], notes: ""
        )],
        localTools: [], templates: []
    )
    package.governance = .builtInApproved(riskLevel: .medium)
    return package
}

/// A connector with `original`'s namespace-defining facts under a new ID.
private func recreation(of original: Connector) -> Connector {
    let copy = Connector(name: original.name, serviceType: original.serviceType, baseURL: original.baseURL)
    copy.originPackageID = original.originPackageID
    copy.originComponentID = original.originComponentID
    return copy
}

@Suite("Connector credential cleanup", .serialized)
@MainActor
struct ConnectorCredentialCleanupTests {
    @Test("A deleted connector's cleanup keeps the stable namespace a recreated connector still reads")
    func cleanupSparesSharedStableNamespace() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let recreated = recreation(of: deleted)
            context.insert(deleted)
            context.insert(recreated)
            try context.save()
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))

            let cleanup = deleted.keychainCleanup
            context.delete(deleted)
            try context.save()
            #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: context))
            #expect(KeychainService.load(key: "TOKEN", connector: recreated) == "shared")
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)

            // Once nothing shares it, the stable namespace goes too.
            let last = recreated.keychainCleanup
            context.delete(recreated)
            try context.save()
            #expect(ConnectorCredentialCleanup.run([last], modelContext: context))
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == nil)
        }
    }

    @Test("The cleanup outbox lives beside the store it describes, and an in-memory store has none")
    func outboxLivesBesideItsStore() throws {
        let memory = try credentialCleanupContainer()
        #expect(ConnectorCredentialCleanupStore(for: memory.mainContext) == nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: folder.appendingPathComponent("default.store"))]
        )
        let outbox = try #require(ConnectorCredentialCleanupStore(for: disk.mainContext))
        #expect(WorkspacePathPresentation.resolvedPath(outbox.directory.deletingLastPathComponent().path)
            == WorkspacePathPresentation.resolvedPath(folder.path))
        withExtendedLifetime(disk) {}
        // The app's own store, active or replaced by a recovery, shares one
        // outbox in Application Support, so a recovery strands nothing.
        let support = folder.appendingPathComponent("Support", isDirectory: true)
        let shared = support.appendingPathComponent("ConnectorCredentialCleanup").path
        #expect(ConnectorCredentialCleanupStore.directory(
            forStoreAt: support.appendingPathComponent("Stores/g1/default.store"), applicationSupport: support
        ).path == shared)
        #expect(ConnectorCredentialCleanupStore.directory(
            forStoreAt: support.appendingPathComponent("Stores/g1/recoveries/\(UUID().uuidString)/default.store"),
            applicationSupport: support
        ).path == shared)
    }

    @Test("An intent that can't be decoded holds back the batch until it can")
    func corruptIntentHoldsBackTheBatch() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([deleted.keychainCleanup])
            outbox.markCommitted([deleted.keychainCleanup])
            let corrupt = outbox.directory.appendingPathComponent("unrelated.json")
            try Data("{".utf8).write(to: corrupt)

            #expect(outbox.pending()?.complete == false)
            #expect(outbox.pending()?.records.map(\.cleanup) == [deleted.keychainCleanup])
            // It may name an owner no other record shows: nothing runs.
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 0)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(FileManager.default.fileExists(atPath: corrupt.path))
            // Once it reads, or is gone, the batch runs.
            try FileManager.default.removeItem(at: corrupt)
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
        }
    }

    @Test("A connector a pending workspace deletion still holds keeps the namespaces it shares")
    func pendingWorkspaceDeletionRetainsSharedNamespaces() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            // Held only by a workspace deletion whose mirror may be recovered.
            let retained = recreation(of: deleted)
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            #expect(ConnectorCredentialCleanup.run(
                [deleted.keychainCleanup], modelContext: context, retained: [retained.keychainCleanup]
            ))
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
        }
        // The deletion outbox reports what its records hold, and nothing at
        // all when a record can't be read.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = WorkspaceDeletionCleanupStore(directory: folder)
        #expect(outbox.pendingConnectors()?.isEmpty == true)
        let held = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
        try outbox.write(WorkspaceDeletionCleanupRecord(
            workspaceID: UUID(), primaryPath: folder.appendingPathComponent("Deleted").path,
            connectors: [held.keychainCleanup], skills: []
        ))
        #expect(outbox.pendingConnectors() == [held.keychainCleanup])
        try Data("{".utf8).write(to: folder.appendingPathComponent("broken.json"))
        #expect(outbox.pendingConnectors() == nil)
    }

    @Test("An intent whose connector is still stored is discarded without a deletion audit")
    func staleIntentIsNotAuditedAsDeletion() throws {
        let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
        // Still stored, as after a deletion that wasn't saved, it owns every
        // namespace its cleanup would touch, so none is run and no deletion
        // happened to audit.
        let ownership = ConnectorCredentialCleanup.Ownership([deleted])
        var audited: [UUID] = []
        #expect(ConnectorCredentialCleanup.run([deleted.keychainCleanup], ownership: ownership, committed: false) {
            audited.append($0.connectorID)
        })
        #expect(audited.isEmpty)
    }

    @Test("An unsaved deletion's intent leaves a connector edited since alone; a saved one cleans what it left")
    func unsavedIntentSparesEditedConnector() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            context.insert(connector)
            try context.save()
            let oldStable = try #require(KeychainSecretStore.stableConnectorEntityID(for: connector))
            #expect(AstraSecureKeychainStore.save(service: oldStable, account: "TOKEN", value: "old", label: nil))
            // The intent outlived a deletion that was never saved, and the
            // stored connector moved to another endpoint since.
            let cleanup = connector.keychainCleanup
            _ = try outbox.record([cleanup])
            connector.baseURL = "https://jira-new.example.invalid"
            try context.save()
            #expect(outbox.pending()?.records.map(\.committed) == [false])
            var audited: [UUID] = []
            #expect(ConnectorCredentialCleanup.run(
                [cleanup], ownership: ConnectorCredentialCleanup.Ownership([connector]), committed: false
            ) { audited.append($0.connectorID) })
            #expect(audited.isEmpty)
            #expect(AstraSecureKeychainStore.load(service: oldStable, account: "TOKEN") == "old")
            // The retry drops the record without touching anything.
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(outbox.pending()?.records.isEmpty == true)
            #expect(AstraSecureKeychainStore.load(service: oldStable, account: "TOKEN") == "old")

            // Marked saved, the same intent is a deletion even with that ID
            // stored again, and cleans the namespace no one uses.
            _ = try outbox.record([cleanup])
            outbox.markCommitted([cleanup])
            #expect(outbox.pending()?.records.map(\.committed) == [true])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: oldStable, account: "TOKEN") == nil)
            // Removing a record takes its mark with it.
            #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.directory.path).isEmpty)
        }
    }

    @Test("An intent not marked saved runs only against the store it was recorded for, once that store lacks its connector")
    func uncommittedIntentNeverRuns() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            // Recorded, then the process exited before the save; the store a
            // recovery replaced it with lacks the connector.
            let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: connector.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([connector.keychainCleanup], storeIdentity: "another-store")
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(outbox.pending()?.records.isEmpty == true)

            // Recorded against this very store, which no longer holds the
            // connector: the deletion was saved and the quit came before its
            // mark, so the cleanup runs.
            _ = try outbox.record([connector.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            #expect(outbox.pending()?.records.map(\.committed) == [false])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.directory.path).isEmpty)
        }
    }

    @Test("A cleanup that runs clears an identical record an earlier deletion left")
    func successfulCleanupClearsReusedRecord() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            context.insert(connector)
            try context.save()
            let cleanup = connector.keychainCleanup
            // An earlier deletion of the same connector left its record.
            _ = try outbox.record([cleanup])
            outbox.markCommitted([cleanup])
            context.delete(connector)
            #expect(ConnectorCredentialCleanup.deleteThenClean([cleanup], modelContext: context, store: outbox, cleansNow: true) {
                (try? context.save()) != nil
            })
            #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.directory.path).isEmpty)
        }
    }

    @Test("A saved workspace deletion cleans its connectors even after its ID is reused; an unsaved one cleans none")
    func workspaceDeletionCommitIsMarkedNotInferred() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = WorkspaceDeletionCleanupStore(directory: folder)
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            let workspaceID = UUID()
            let record = WorkspaceDeletionCleanupRecord(
                workspaceID: workspaceID, primaryPath: folder.appendingPathComponent("Deleted").path,
                connectors: [deleted.keychainCleanup], skills: []
            )
            // A workspace imported since under the same ID, without the connector.
            let reimported = Workspace(name: "Again", primaryPath: folder.appendingPathComponent("Again").path)
            reimported.id = workspaceID
            context.insert(reimported)
            try context.save()

            // Never marked saved: nothing proves the deletion, so its
            // credentials stay, whatever the store holds.
            try outbox.write(record)
            #expect(outbox.isCommitted(record) == false)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")

            // Marked saved, the reused ID doesn't make it unsaved.
            try outbox.write(record)
            try outbox.markCommitted(record)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

            // A quit after the save, before the mark: the store it was
            // recorded against no longer holds the workspace, so it was saved.
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            context.delete(reimported)
            try context.save()
            try outbox.write(record)
            try outbox.markStore(record, identity: PersistentStoreIdentity.current(for: context))
            #expect(outbox.isCommitted(record) == false)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    @Test("Workspace deletions: legacy records settle by the store, unconfirmed ones touch nothing, siblings share, unreadable marks wait")
    func workspaceDeletionResumeEdgeCases() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = WorkspaceDeletionCleanupStore(directory: folder)
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            func record(_ name: String, _ connectors: [ConnectorKeychainCleanup]) -> WorkspaceDeletionCleanupRecord {
                WorkspaceDeletionCleanupRecord(
                    workspaceID: UUID(), primaryPath: folder.appendingPathComponent(name).path, connectors: connectors, skills: []
                )
            }

            // Written before store marks existed, its workspace gone: settled.
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            let legacy = record("Legacy", [deleted.keychainCleanup])
            try outbox.write(legacy)
            #expect(outbox.storeMark(of: legacy) == .absent)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)

            // Unconfirmed, from another store: its mirror and credentials stay.
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            let unconfirmed = record("Unconfirmed", [deleted.keychainCleanup])
            let mirror = WorkspaceFileLayout.workspaceConfigFile(for: unconfirmed.primaryPath)
            try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
            try outbox.write(unconfirmed)
            try outbox.markStore(unconfirmed, identity: "another-store")
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(FileManager.default.fileExists(atPath: mirror))
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(outbox.pending().isEmpty)

            // A store mark that can't be read leaves the record for later.
            let waiting = record("Waiting", [deleted.keychainCleanup])
            try outbox.write(waiting)
            try outbox.markStore(waiting, identity: "store")
            let mark = outbox.recordURL(for: waiting).appendingPathExtension("store").path
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mark)
            #expect(outbox.storeMark(of: waiting) == .unreadable)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mark)
            outbox.remove(waiting)

            // Two saved deletions share a stable namespace: settling one spares
            // what the other, still pending, holds.
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            let first = record("First", [deleted.keychainCleanup])
            let second = record("Second", [recreation(of: deleted).keychainCleanup])
            for pending in [first, second] {
                try outbox.write(pending)
                try outbox.markCommitted(pending)
            }
            #expect(WorkspaceDeletionCleanupService.settle(
                first, modelContext: context, retained: try #require(outbox.records(pendingBesides: first)).flatMap(\.connectors)
            ))
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
            outbox.remove(first)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == nil)

            // An unconfirmed record settled first in the batch still holds its
            // connectors while a saved sibling settles after it.
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            let early = WorkspaceDeletionCleanupRecord(
                workspaceID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                primaryPath: folder.appendingPathComponent("Early").path, connectors: [deleted.keychainCleanup], skills: []
            )
            let late = WorkspaceDeletionCleanupRecord(
                workspaceID: try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")),
                primaryPath: folder.appendingPathComponent("Late").path, connectors: [recreation(of: deleted).keychainCleanup], skills: []
            )
            try outbox.write(early)
            try outbox.markStore(early, identity: "another-store")
            try outbox.write(late)
            try outbox.markCommitted(late)
            #expect(outbox.pending().map(\.workspaceID) == [early.workspaceID, late.workspaceID])
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 2)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
        }
    }

    @Test("Workspace cleanup spares unconfirmed connector intents and sibling skills, and drops unconfirmed records only when told")
    func workspaceCleanupSparesOtherQueuesOwners() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-outbox-\(UUID().uuidString)")
        let connectorOutbox = ConnectorCredentialCleanupStore(directory: folder.appendingPathComponent("Connectors"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = WorkspaceDeletionCleanupStore(directory: folder.appendingPathComponent("Workspaces"))
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            let skillID = UUID()
            let skillCleanup = try JSONDecoder().decode(
                SkillKeychainCleanup.self, from: Data(#"{"skillID":"\#(skillID.uuidString)"}"#.utf8)
            )
            let skillService = KeychainSecretStore.skillEntityID(for: skillID)
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            #expect(AstraSecureKeychainStore.save(service: skillService, account: "KEY", value: "skill", label: nil))
            // An unconfirmed connector intent shares the namespace.
            _ = try connectorOutbox.record([recreation(of: deleted).keychainCleanup], storeIdentity: "another-store")
            // An unconfirmed workspace deletion shares the skill.
            let unconfirmed = WorkspaceDeletionCleanupRecord(
                workspaceID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
                primaryPath: folder.appendingPathComponent("Unconfirmed").path, connectors: [],
                skills: [skillCleanup]
            )
            try outbox.write(unconfirmed)
            try outbox.markStore(unconfirmed, identity: "another-store")
            let saved = WorkspaceDeletionCleanupRecord(
                workspaceID: try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")),
                primaryPath: folder.appendingPathComponent("Saved").path, connectors: [deleted.keychainCleanup],
                skills: [skillCleanup]
            )
            try outbox.write(saved)
            try outbox.markCommitted(saved)

            #expect(WorkspaceDeletionCleanupService.resumePending(
                modelContext: context, store: outbox, connectorOutbox: connectorOutbox, dropsUnconfirmed: false
            ) == 1)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
            #expect(AstraSecureKeychainStore.load(service: skillService, account: "KEY") == "skill")
            // Kept until the connector pass has run, then dropped.
            #expect(outbox.pending() == [unconfirmed])
            // Dropping it lets nothing force the next launch's scan, so a
            // rescan marker goes down first; one that can't be written keeps it.
            let marker = folder.appendingPathComponent("Rescan")
            let blocked = folder.appendingPathComponent("NotAFolder")
            try Data().write(to: blocked)
            #expect(WorkspaceDeletionCleanupService.dropUnconfirmed(
                modelContext: context, store: outbox, rescanMarker: blocked.appendingPathComponent("Rescan")
            ) == 0)
            #expect(outbox.pending() == [unconfirmed])
            #expect(WorkspaceDeletionCleanupService.dropUnconfirmed(modelContext: context, store: outbox, rescanMarker: marker) == 1)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(outbox.pending().isEmpty)
        }
        // Deleting a workspace or a connector in the app cleans up only once
        // a trusted launch's recovery has run.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(contentsOf: root.appendingPathComponent("Astra/Services/Tasks/TaskLifecycleCoordinator.swift"), encoding: .utf8)
        #expect(coordinator.contains("if WorkspaceRecoveryTrust.allowsCleanup,\n               let others = store.records(pendingBesides: pinned)"))
        let cleanup = try String(contentsOf: root.appendingPathComponent("Astra/Services/Capabilities/ConnectorCredentialCleanup.swift"), encoding: .utf8)
        #expect(cleanup.contains("let cleansNow = cleansNow ?? (WorkspaceRecoveryTrust.state == .notTracked)"))
    }

    @Test("Recovery leaves out a mirror whose workspace was deleted while it loaded")
    func recoveryRechecksDeletionsBeforeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-recovery-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try credentialCleanupContainer()
        let workspace = Workspace(name: "Deleted", primaryPath: folder.path)
        source.mainContext.insert(workspace)
        try source.mainContext.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.mainContext, url: mirror)
        let emptyRoot = root.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        var reported: [URL] = []
        var loaded: [URL] = []
        func recover(_ deletedNow: (paths: Set<String>, workspaceIDs: Set<String>)?) async throws -> (trusted: Bool, names: [String]) {
            let lost = try credentialCleanupContainer()
            let trusted = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
                modelContext: lost.mainContext, extraRoots: [emptyRoot.path], includeDefaultRoots: false,
                registeredFolders: [folder.path], deletionMirrorsNow: { deletedNow },
                excludedByWorkspaceID: { reported += $0 }, loadedMirrors: { loaded = $0 }
            ).value
            return (trusted, try lost.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.name))
        }
        #expect(try await recover(([], [])).names == ["Deleted"])
        // Every mirror it loaded is reported for cleanup to reconcile.
        #expect(loaded.map(\.path) == [mirror.path])
        // Deleted after the scan began: the mirror is pending deletion now.
        let deleted = try await recover(([WorkspacePathPresentation.resolvedPath(mirror.path)], []))
        #expect(deleted.trusted)
        #expect(deleted.names.isEmpty)
        // Its folder moved before the deletion: matched by its ID instead.
        #expect(reported.isEmpty)
        let moved = try await recover(([], [workspace.id.uuidString]))
        #expect(moved.trusted)
        #expect(moved.names.isEmpty)
        // Reported, and settlement removes it though no identity was pinned
        // for it: it names the deleted workspace.
        #expect(reported.map(\.path) == [mirror.path])
        // Any spelling of the ID matches, as the importer reads it.
        #expect(try await recover(([], [workspace.id.uuidString.lowercased()])).names.isEmpty)
        // A reported mirror that can't be read keeps the deletion pending.
        let unreadable = root.appendingPathComponent("Unreadable.json")
        try FileManager.default.copyItem(at: mirror, to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let pendingCheck = try credentialCleanupContainer()
        #expect(!WorkspaceDeletionCleanupService.settle(
            WorkspaceDeletionCleanupRecord(
                workspaceID: workspace.id, primaryPath: root.appendingPathComponent("OldPath").path, connectors: [], skills: []
            ),
            modelContext: pendingCheck.mainContext, movedMirrors: [unreadable.path]
        ))
        let settling = try credentialCleanupContainer()
        let record = WorkspaceDeletionCleanupRecord(
            workspaceID: workspace.id, primaryPath: root.appendingPathComponent("OldPath").path, connectors: [], skills: []
        )
        #expect(WorkspaceDeletionCleanupService.settle(record, modelContext: settling.mainContext, movedMirrors: reported.map(\.path)))
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        // Pending deletions that can't be read import nothing.
        let unread = try await recover(nil)
        #expect(!unread.trusted)
        #expect(unread.names.isEmpty)
        withExtendedLifetime(source) {}
    }

    @Test("A saved connector deletion waits while a stored workspace's mirror still lists the connector")
    func cleanupWaitsForStaleMirror() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-stale-mirror-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try withTemporaryCredentialKeychain {
            let folder = root.appendingPathComponent("App", isDirectory: true)
            let workspace = Workspace(name: "App", primaryPath: folder.path)
            context.insert(workspace)
            try context.save()
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])
            // The deletion saved, but the quit came before the export.
            let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"connectors":[{"id":"\#(deleted.id.uuidString)"}]}"#.utf8).write(to: mirror)
            #expect(ConnectorCredentialCleanup.connectorsInStoredMirrors(modelContext: context)?.ids == [deleted.id])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 0)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            // Once the mirror no longer lists it, the cleanup runs.
            try Data(#"{"connectors":[]}"#.utf8).write(to: mirror)
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            // A mirror that can't be read runs nothing. Another workspace's,
            // since the first is being exported again in the background.
            let other = Workspace(name: "Other", primaryPath: root.appendingPathComponent("Other").path)
            context.insert(other)
            try context.save()
            let corrupt = URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: other.primaryPath))
            try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{".utf8).write(to: corrupt)
            #expect(ConnectorCredentialCleanup.connectorsInStoredMirrors(modelContext: context) == nil)
        }
    }

    @Test("Stale-mirror intents and ID-less mirror connectors stay owners, and a failed workspace deletion restores its store mark")
    func mirrorOwnersAndRestoredStoreMark() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-owners-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let connectorOutbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Connectors"))
        let outbox = WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("Workspaces"))
        try withTemporaryCredentialKeychain {
            let folder = root.appendingPathComponent("App", isDirectory: true)
            let workspace = Workspace(name: "App", primaryPath: folder.path)
            context.insert(workspace)
            try context.save()
            let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            // A saved connector deletion its workspace's mirror still lists.
            try Data(#"{"connectors":[{"id":"\#(deleted.id.uuidString)"}]}"#.utf8).write(to: mirror)
            _ = try connectorOutbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            connectorOutbox.markCommitted([deleted.keychainCleanup])
            #expect(ConnectorCredentialCleanup.unconfirmedOwners(modelContext: context, store: connectorOutbox)?
                .contains(deleted.keychainCleanup) == true)
            // A saved workspace deletion sharing the namespace spares it.
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            let sibling = WorkspaceDeletionCleanupRecord(
                workspaceID: UUID(), primaryPath: root.appendingPathComponent("Gone").path,
                connectors: [recreation(of: deleted).keychainCleanup], skills: []
            )
            try outbox.write(sibling)
            try outbox.markCommitted(sibling)
            #expect(WorkspaceDeletionCleanupService.resumePending(
                modelContext: context, store: outbox, connectorOutbox: connectorOutbox
            ) == 1)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")

            // A mirror listing the connector without an ID keeps its namespace
            // from a saved cleanup: an import would restore it under a new ID.
            try Data(#"{"connectors":[{"name":"Jira","serviceType":"jira","baseURL":"https://jira.example.invalid"}]}"#.utf8)
                .write(to: mirror)
            let mirrored = try #require(ConnectorCredentialCleanup.connectorsInStoredMirrors(modelContext: context))
            #expect(mirrored.ids.isEmpty)
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: connectorOutbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
        }

        // Deleting the workspace again fails to save: the reused record keeps
        // naming the earlier store.
        let earlier = WorkspaceDeletionCleanupRecord(workspace(in: context))
        try outbox.write(earlier)
        try outbox.markStore(earlier, identity: "another-store")
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0),
            worktreeCleanupStore: TaskWorktreeCleanupStore(directory: root.appendingPathComponent("WorktreeCleanup")),
            workspaceDeletionCleanupStore: outbox, persistWorkspaceChange: { _, _ in false }
        )
        let stored = workspace(in: context)
        #expect(!coordinator.deleteWorkspace(stored, existingWorkspaces: [stored]).persisted)
        #expect(outbox.storeMark(of: earlier) == .recorded("another-store"))
    }

    private func workspace(in context: ModelContext) -> Workspace {
        (try? context.fetch(FetchDescriptor<Workspace>()).first { $0.name == "App" })!
    }

    @Test("Cleanup reconciles every mirror recovery loaded, runs once the connector is stored again, and needs the store's identity")
    func cleanupReconcilesLoadedMirrorsAndNeedsStoreIdentity() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-loaded-mirrors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            _ = try outbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([deleted.keychainCleanup])
            // An old copy recovery loaded but didn't import still lists it.
            let copy = root.appendingPathComponent("OldCopy/.astra/.astra-workspace.json")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"connectors":[{"id":"\#(deleted.id.uuidString)"}]}"#.utf8).write(to: copy)
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox, extraMirrors: [copy.path]) == 0)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            // Restored from that copy under its ID, the connector owns what it
            // uses, and the obsolete intent runs and goes.
            context.insert(deleted)
            try context.save()
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox, extraMirrors: [copy.path]) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(outbox.pending()?.records.isEmpty == true)
        }

        // A store that can't be identified deletes nothing.
        let storeURL = root.appendingPathComponent("Store/default.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: storeURL)])
        try disk.mainContext.save()
        #expect(PersistentStoreIdentity.current(for: disk.mainContext) != nil)
        try FileManager.default.removeItem(at: storeURL)
        #expect(PersistentStoreIdentity.current(for: disk.mainContext) == nil)
        var saved = false
        #expect(!ConnectorCredentialCleanup.deleteThenClean(
            [Connector(name: "Jira", serviceType: "jira").keychainCleanup], modelContext: disk.mainContext, store: outbox
        ) { saved = true; return true })
        #expect(!saved)
        withExtendedLifetime(disk) {}

        // Every pending deletion's ID filters recovery, those pending at launch included.
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8
        )
        #expect(app.contains("(paths, Set(deletionStore.pending().map(\\.workspaceID.uuidString)))"))
        #expect(!app.contains("launchDeletionIDs"))
        #expect(app.contains("loadedMirrors: { WorkspaceRecoveryTrust.recordLoadedMirrors($0.map(\\.path)) }"))
    }

    @Test("Every loaded mirror's connectors and skills are owners, its own deletion's aside, and an unidentified store waits")
    func loadedMirrorsOwnEverythingTheyList() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-listing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let connectorOutbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Connectors"))
        let outbox = WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("Workspaces"))
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let other = recreation(of: deleted)
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            let skillID = UUID()
            let skillService = KeychainSecretStore.skillEntityID(for: skillID)
            for (service, value) in [(own, "own"), (stable, "shared")] {
                #expect(AstraSecureKeychainStore.save(service: service, account: "TOKEN", value: value, label: nil))
            }
            #expect(AstraSecureKeychainStore.save(service: skillService, account: "KEY", value: "skill", label: nil))
            // An old copy of another workspace lists a connector, by a valid
            // ID, sharing the namespace, and a skill.
            let copy = root.appendingPathComponent("Copy/.astra/.astra-workspace.json")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"""
            {"id":"\#(UUID().uuidString)","connectors":[{"id":"\#(other.id.uuidString)","name":"Jira","serviceType":"jira","baseURL":"https://jira.example.invalid"}],"skills":[{"id":"\#(skillID.uuidString)"}]}
            """#.utf8).write(to: copy)

            // A saved connector deletion spares the shared namespace.
            _ = try connectorOutbox.record([deleted.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            connectorOutbox.markCommitted([deleted.keychainCleanup])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: connectorOutbox, extraMirrors: [copy.path]) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")

            // A saved workspace deletion spares the skill the copy lists...
            let record = WorkspaceDeletionCleanupRecord(
                workspaceID: UUID(), primaryPath: root.appendingPathComponent("Gone").path, connectors: [],
                skills: [try JSONDecoder().decode(SkillKeychainCleanup.self, from: Data(#"{"skillID":"\#(skillID.uuidString)"}"#.utf8))]
            )
            try outbox.write(record)
            try outbox.markCommitted(record)
            #expect(WorkspaceDeletionCleanupService.resumePending(
                modelContext: context, store: outbox, connectorOutbox: connectorOutbox, extraMirrors: [copy.path]
            ) == 1)
            #expect(AstraSecureKeychainStore.load(service: skillService, account: "KEY") == "skill")
            // ...but a copy of the workspace being deleted names nothing.
            let ownCopy = root.appendingPathComponent("OwnCopy.json")
            try Data(#"{"id":"\#(record.workspaceID.uuidString)","skills":[{"id":"\#(skillID.uuidString)"}]}"#.utf8).write(to: ownCopy)
            #expect(ConnectorCredentialCleanup.connectorsInStoredMirrors(
                modelContext: context, extraMirrors: [ownCopy.path], excludingWorkspaceIDs: [record.workspaceID]
            )?.skillIDs.isEmpty == true)
        }

        // An unidentifiable active store: unmarked records wait, and a
        // mutation with no connector cleanup still saves.
        let storeURL = root.appendingPathComponent("Store/default.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: storeURL)])
        try disk.mainContext.save()
        try FileManager.default.removeItem(at: storeURL)
        let unmarked = WorkspaceDeletionCleanupRecord(
            workspaceID: UUID(), primaryPath: root.appendingPathComponent("Unmarked").path, connectors: [], skills: []
        )
        try outbox.write(unmarked)
        try outbox.markStore(unmarked, identity: "some-store")
        #expect(WorkspaceDeletionCleanupService.classify(store: outbox, modelContext: context) { _ in nil }?
            .first { $0.record == unmarked }?.disposition == .wait)
        #expect(WorkspaceDeletionCleanupService.classify(store: outbox, modelContext: context)?
            .first { $0.record == unmarked }?.disposition == .unconfirmed)
        var saved = false
        #expect(ConnectorCredentialCleanup.deleteThenClean([], modelContext: disk.mainContext, store: connectorOutbox) {
            saved = true
            return true
        })
        #expect(saved)
        withExtendedLifetime(disk) {}

        // Deleting a workspace removes the loaded copies of it too.
        let coordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/Services/Tasks/TaskLifecycleCoordinator.swift"), encoding: .utf8
        )
        #expect(coordinator.contains("movedMirrors: WorkspaceRecoveryTrust.loadedMirrors"))
    }

    @Test("A connector intent whose store mark can't be read waits")
    func unreadableStoreMarkWaits() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
        let urls = try outbox.record([connector.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
        let mark = try #require(urls.first).appendingPathExtension("store").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mark)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mark) }
        // Held back: not run, but an owner of what it names meanwhile.
        #expect(outbox.pending()?.records.isEmpty == true)
        #expect(outbox.pending()?.heldBack == [connector.keychainCleanup])
        #expect(ConnectorCredentialCleanup.unconfirmedOwners(modelContext: context, store: outbox) == [connector.keychainCleanup])
        #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 0)
        #expect(FileManager.default.fileExists(atPath: try #require(urls.first).path))
    }

    @Test("A held-back intent keeps its namespace from a saved sibling, and a failed save restores a reused intent's store mark")
    func heldBackAndReusedIntentsKeepOwnership() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let earlier = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let later = recreation(of: earlier)
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: earlier))
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            let held = try #require(try outbox.record([earlier.keychainCleanup], storeIdentity: "another-store").first)
            let mark = held.appendingPathExtension("store").path
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mark)
            _ = try outbox.record([later.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([later.keychainCleanup])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mark)

            // Deleted again, but the save fails: the intent names its earlier
            // store again, not this one.
            context.insert(earlier)
            try context.save()
            context.delete(earlier)
            #expect(!ConnectorCredentialCleanup.deleteThenClean(
                [earlier.keychainCleanup], modelContext: context, store: outbox, cleansNow: false
            ) { false })
            #expect(outbox.pending()?.records.map(\.storeIdentity) == ["another-store"])
        }
    }

    @Test("An unconfirmed intent keeps what it uses while others run, and a reused intent names its new store")
    func unconfirmedIntentsStayOwners() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let earlier = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let later = recreation(of: earlier)
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: earlier))
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            // One intent from a store since replaced, unconfirmed; one saved.
            _ = try outbox.record([earlier.keychainCleanup], storeIdentity: "another-store")
            _ = try outbox.record([later.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([later.keychainCleanup])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 2)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")

            // Still an owner when the store now holds a connector with its ID
            // at another endpoint: the earlier store's may use the old one.
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            let moved = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira-moved.example.invalid")
            moved.id = earlier.id
            context.insert(moved)
            try context.save()
            _ = try outbox.record([earlier.keychainCleanup], storeIdentity: "another-store")
            _ = try outbox.record([later.keychainCleanup], storeIdentity: PersistentStoreIdentity.current(for: context))
            outbox.markCommitted([later.keychainCleanup])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 2)
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == "shared")
            context.delete(moved)
            try context.save()

            // Recorded again for a new attempt, an intent names that attempt's store.
            _ = try outbox.record([earlier.keychainCleanup], storeIdentity: "another-store")
            _ = try outbox.record([earlier.keychainCleanup], storeIdentity: "this-store")
            #expect(outbox.pending()?.records.map(\.storeIdentity) == ["this-store"])
        }
    }

    @Test("A pre-mark workspace deletion written before this store existed is kept, not settled")
    func legacyDeletionBeforeStoreIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("Store/default.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: storeURL)])
        let context = disk.mainContext
        try context.save()
        let outbox = WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("Outbox"))
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            let record = WorkspaceDeletionCleanupRecord(
                workspaceID: UUID(), primaryPath: root.appendingPathComponent("Gone").path,
                connectors: [deleted.keychainCleanup], skills: []
            )
            try outbox.write(record)
            // Written before this store was created, as before a recovery.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: outbox.recordURL(for: record).path
            )
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 0)
            #expect(outbox.pending() == [record])
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            // Written for this store, it settles as a saved deletion.
            try outbox.write(record)
            #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
        }
        withExtendedLifetime(disk) {}
    }

    @Test("A launch that trusts the store without scanning lets no credential cleanup run")
    func cleanupWaitsWhenStoreVouchesWithoutScan() async throws {
        #expect(!WorkspaceRecoveryTrust.allowsCleanup(in: .vouchedWithoutScan))
        #expect(!WorkspaceRecoveryTrust.allowsCleanup(in: .pending))
        #expect(!WorkspaceRecoveryTrust.allowsCleanup(in: .untrusted))
        #expect(WorkspaceRecoveryTrust.allowsCleanup(in: .trusted))
        #expect(WorkspaceRecoveryTrust.allowsCleanup(in: .notTracked))
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        context.insert(Workspace(name: "App", primaryPath: "/nonexistent/astra-vouch-\(UUID().uuidString)"))
        try context.save()
        // A store with workspaces and nothing pending vouches without a scan
        // and says so; one that scans, here a scratch root, doesn't.
        var vouched = 0
        #expect(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: context, vouchedWithoutScan: { vouched += 1 }
        ).value)
        #expect(vouched == 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-vouch-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: context, extraRoots: [root.path], includeDefaultRoots: false, vouchedWithoutScan: { vouched += 1 }
        ).value
        #expect(vouched == 1)
    }

    @Test("Before launch recovery vouches for the store, a saved deletion's cleanup waits in the outbox")
    func cleanupWaitsForTrustedRecovery() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            context.insert(connector)
            try context.save()
            let own = KeychainSecretStore.connectorEntityID(for: connector.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))
            let cleanup = connector.keychainCleanup
            context.delete(connector)
            // A connector only a mirror still holds could share a namespace,
            // so nothing is removed yet.
            #expect(ConnectorCredentialCleanup.deleteThenClean([cleanup], modelContext: context, store: outbox, cleansNow: false) {
                (try? context.save()) != nil
            })
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(outbox.pending()?.records.map(\.cleanup) == [cleanup])
            // The trusted launch's retry clears it.
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
        }
        // The app marks recovery pending before it starts and trusted only
        // where it vouches for the store.
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8
        )
        let pending = try #require(app.range(of: "WorkspaceRecoveryTrust.set(.pending)"))
        let recovery = try #require(app.range(of: "WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch("))
        let trusted = try #require(app.range(
            of: "WorkspaceRecoveryTrust.set(recoveryVouchedWithoutScan ? .vouchedWithoutScan : .trusted)"
        ))
        #expect(app.contains("vouchedWithoutScan: { recoveryVouchedWithoutScan = true }"))
        let vouched = try #require(app.range(of: "workspaceRecoveryTrusted = true"))
        #expect(pending.lowerBound < recovery.lowerBound)
        // Pending connector cleanup keeps launch recovery from trusting a
        // nonempty store without scanning, as worktree cleanup does.
        #expect(app.contains("let connectorCleanup = ConnectorCredentialCleanupStore(for: modelContext).map"))
        #expect(app.contains("|| connectorCleanup"))
        // A launch that skipped the scan resumes no credential cleanup, and
        // an unconfirmed workspace deletion is dropped only after both passes.
        let gate = try #require(app.range(of: "if WorkspaceRecoveryTrust.allowsCleanup {\n                    WorkspaceDeletionCleanupService.resumePending("))
        let connectors = try #require(app.range(of: "ConnectorCredentialCleanup.resumePending(modelContext: modelContext)", range: gate.upperBound..<app.endIndex))
        let drop = try #require(app.range(of: "WorkspaceDeletionCleanupService.dropUnconfirmed(\n                        modelContext: modelContext, rescanMarker: WorkspaceRecoveryService.defaultIncompleteRecoveryMarker", range: connectors.upperBound..<app.endIndex))
        #expect(app[gate.upperBound..<drop.lowerBound].contains("dropsUnconfirmed: false"))
        #expect(app.components(separatedBy: "ConnectorCredentialCleanup.resumePending(").count == 2)
        #expect(vouched.upperBound <= trusted.lowerBound)
        #expect(WorkspaceRecoveryTrust.state == .notTracked)
    }

    @Test("A pending intent that doesn't read back as the same cleanup stops the deletion")
    func corruptExistingIntentStopsDeletion() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
        context.insert(connector)
        try context.save()
        let cleanup = connector.keychainCleanup
        let recorded = try #require(try outbox.record([cleanup]).first)
        // Truncated where it already stood.
        try Data("{".utf8).write(to: recorded)
        var saved = false
        #expect(!ConnectorCredentialCleanup.deleteThenClean([cleanup], modelContext: context, store: outbox) {
            saved = true
            return true
        })
        #expect(!saved)
        #expect(try Data(contentsOf: recorded) == Data("{".utf8))
    }

    @Test("A Configure deletion whose save fails is rolled back with its membership and records nothing")
    func failedConfigureDeletionRollsBack() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let outbox = ConnectorCredentialCleanupStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: outbox.directory) }
        try withTemporaryCredentialKeychain {
            let workspace = Workspace(name: "WS", primaryPath: "/tmp/astra-connector-cleanup-ws")
            let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            connector.isGlobal = true
            context.insert(workspace)
            context.insert(connector)
            workspace.enabledGlobalConnectorIDs = [connector.id.uuidString]
            try context.save()
            let own = KeychainSecretStore.connectorEntityID(for: connector.id)
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))

            #expect(!ConnectorCredentialCleanup.deleteConnector(connector, in: workspace, modelContext: context, store: outbox) { false })
            // Nothing a later save could commit without its cleanup.
            #expect(!connector.isDeleted)
            try context.save()
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<Connector>()) == 1)
            #expect(workspace.enabledGlobalConnectorIDs == [connector.id.uuidString])
            #expect(outbox.pending()?.records.isEmpty == true)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")

            #expect(ConnectorCredentialCleanup.deleteConnector(connector, in: workspace, modelContext: context, store: outbox) {
                (try? context.save()) != nil
            })
            #expect(try context.fetchCount(FetchDescriptor<Connector>()) == 0)
            #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(outbox.pending()?.records.isEmpty == true)
        }
    }

    @Test("A cleanup that fails after the deletion is saved stays pending and is retried at launch")
    func failedPostSaveCleanupIsRetried() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-connector-cleanup-\(UUID().uuidString)")
        let outbox = ConnectorCredentialCleanupStore(directory: root.appendingPathComponent("Outbox"))
        let registryFolder = root.appendingPathComponent("Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: registryFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registryFolder.path)
            try? FileManager.default.removeItem(at: root)
        }
        try withTemporaryCredentialKeychain {
            try StanfordOutlookMail.$registryURLOverride.withValue(registryFolder.appendingPathComponent("mail-accounts.json")) {
                let connector = Connector(name: "Stanford Outlook Mail")
                connector.applyStanfordOutlookDefaults()
                context.insert(connector)
                try context.save()
                StanfordOutlookMailRegistry.upsert(connector: connector)
                let cleanup = connector.keychainCleanup
                context.delete(connector)
                // The registry can't be rewritten, so the saved deletion's
                // cleanup can't clear it now.
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registryFolder.path)
                #expect(ConnectorCredentialCleanup.deleteThenClean([cleanup], modelContext: context, store: outbox) {
                    (try? context.save()) != nil
                })
                #expect(outbox.pending()?.records.map(\.cleanup) == [cleanup])
                #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 0)
                #expect(outbox.pending()?.records.count == 1)

                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registryFolder.path)
                #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
                #expect(StanfordOutlookMailRegistry.entries().isEmpty)
                #expect(outbox.pending()?.records.isEmpty == true)
            }
        }
        // Startup retries them only once recovery vouches for the store.
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8
        )
        let trusted = try #require(app.range(of: "workspaceRecoveryTrusted = true"))
        #expect(app.range(of: "ConnectorCredentialCleanup.resumePending(modelContext: modelContext)", range: trusted.upperBound..<app.endIndex) != nil)
    }

    @Test("Disabling a package keeps the credentials a recreated connector outside it still reads")
    func disableSparesSharedNamespace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-credential-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Shared", primaryPath: root.path)
        context.insert(workspace)
        let package = credentialPackage(id: "shared-pkg")
        let installer = CapabilityInstaller(library: CapabilityLibrary(directory: root), appVersion: SemanticVersion(1, 0, 0))

        try withTemporaryCredentialKeychain {
            _ = try installer.install(
                package, into: workspace, modelContext: context, credentialInputs: ["SVC_TOKEN": "secret-value"]
            )
            let installed = try #require(workspace.connectors.first)
            let recreated = recreation(of: installed)
            recreated.isGlobal = true
            context.insert(recreated)
            try context.save()
            #expect(KeychainService.load(key: "SVC_TOKEN", connector: recreated) == "secret-value")

            let capabilities = WorkspaceCapabilities(
                workspace: workspace,
                globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })),
                globalConnectors: try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
            )
            let installedID = installed.id
            let result = CapabilityActivationDisabler().disable(
                package, in: workspace, capabilities: capabilities, modelContext: context, availablePackages: [package]
            )
            #expect(result.removedWorkspaceConnectorIDs == [installedID])
            #expect(KeychainService.load(key: "SVC_TOKEN", connector: recreated) == "secret-value")
            #expect(KeychainService.load(key: "SVC_TOKEN", connectorID: installedID) == nil)
        }
    }
}
