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

    @Test("A corrupt intent is left for later but never holds back the readable ones")
    func corruptIntentDoesNotBlockOthers() throws {
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
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)
            #expect(FileManager.default.fileExists(atPath: corrupt.path))
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

    @Test("An intent never marked saved runs nothing, even for a connector the store no longer has")
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
            _ = try outbox.record([connector.keychainCleanup])
            #expect(ConnectorCredentialCleanup.resumePending(modelContext: context, store: outbox) == 1)
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == "own")
            #expect(outbox.pending()?.records.isEmpty == true)
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
