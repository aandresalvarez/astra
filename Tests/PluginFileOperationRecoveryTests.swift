import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Prepared plugin file recovery", .serialized)
struct PluginFileOperationRecoveryTests {
    @Test("Prepared or replaced files without a domain commit roll back after reopening", arguments: [false, true])
    func uncommittedReopenRollsBack(filesReplaced: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        if filesReplaced { try fixture.journal.apply(prepared, forward: true) }
        #expect(try fixture.value() == (filesReplaced ? "new definition" : "old definition"))
        let reopened = try fixture.reopen()
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: reopened.mainContext)
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(try fixture.value() == "old definition")
        #expect(try fixture.journal.pendingIDs().isEmpty)
    }

    @Test("A committed zero-activation operation replays exact prepared bytes after reopening")
    func committedReopenRollsForward() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try fixture.commit(prepared)
        // Simulate a file replacement that was interrupted/lost after save.
        try Data("partial replacement".utf8).write(to: fixture.target)
        let reopened = try fixture.reopen()
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: reopened.mainContext)
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(try fixture.value() == "new definition")
        #expect(try PluginOperationCommit.read(prepared.id, container: reopened)?.completedAt != nil)
        #expect(try fixture.journal.pendingIDs().isEmpty)
    }

    @Test("Startup replays files while leaving mirror completion pending")
    func startupSeparatesFilesFromMirrors() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try fixture.commit(prepared)
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(
            modelContext: fixture.context, completesMirrors: false)
        #expect(result.filesReady == 1 && result.deferred == 0 && result.completed == 0)
        #expect(try fixture.value() == "new definition")
        #expect(try PluginOperationCommit.read(prepared.id, container: fixture.container)?.completedAt == nil)
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
        let completed = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: fixture.context)
        #expect(completed.completed == 1 && completed.deferred == 0)
    }

    @Test("A manifest that no longer matches its saved receipt never authorizes replay")
    func modifiedManifestRetainsRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try fixture.commit(prepared)
        let manifest = fixture.journal.directory.appendingPathComponent(prepared.id.uuidString + ".json")
        var bytes = try Data(contentsOf: manifest)
        bytes.append(Data("\n".utf8))
        try bytes.write(to: manifest, options: .atomic)
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: fixture.context)
        #expect(result.completed == 0 && result.deferred == 1)
        #expect(try fixture.value() == "old definition")
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
    }

    @Test("A library-only preparation never creates or modifies an unrelated approval root")
    func unrelatedStorageIsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let approvalRoot = fixture.root.appendingPathComponent("Approvals")
        #expect(!FileManager.default.fileExists(atPath: approvalRoot.path))
        let prepared = try fixture.prepare()
        #expect(!FileManager.default.fileExists(atPath: approvalRoot.path))
        try fixture.journal.apply(prepared, forward: true)
        #expect(!FileManager.default.fileExists(atPath: approvalRoot.path))
    }

    @Test("Wrong stores never decide rollback or overwrite library bytes")
    func wrongStoreRetainsJournal() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try fixture.journal.apply(prepared, forward: true)
        let wrong = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: wrong.mainContext)
        #expect(result.completed == 0 && result.deferred == 1)
        #expect(try fixture.value() == "new definition")
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
    }

    @Test("A blocked mirror retains both receipt debt and prepared file work until retry")
    func mirrorDebtSurvivesAndRetries() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let workspace = Workspace(name: "Affected", primaryPath: "")
        fixture.context.insert(workspace)
        try fixture.context.save()
        let prepared = try fixture.prepare()
        try fixture.commit(prepared, workspaceIDs: [workspace.id])
        let recovery = PluginFileOperationRecovery(journal: fixture.journal)
        let blocked = recovery.resumePending(modelContext: fixture.context, export: { _, _ in false })
        #expect(blocked.completed == 0 && blocked.deferred == 1)
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
        #expect(!PluginOperationRecovery.permitsCredentialCleanup(modelContext: fixture.context))
        let retry = recovery.resumePending(modelContext: fixture.context, export: { _, _ in true })
        #expect(retry.completed == 1 && retry.deferred == 0)
        #expect(PluginOperationRecovery.permitsCredentialCleanup(modelContext: fixture.context))
    }

    @Test("A leftover completed journal never overwrites a later definition")
    func completedJournalOnlyGetsRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try fixture.commit(prepared)
        _ = PluginOperationRecovery.resumePending(modelContext: fixture.context,
            allowsFileOperation: { $0.id == prepared.id })
        try Data("later definition".utf8).write(to: fixture.target)
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: fixture.context)
        #expect(result.completed == 1)
        #expect(try fixture.value() == "later definition")
    }

    @Test("A retargeted storage root keeps recovery pending and does not touch the replacement")
    func changedRootIsNotFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        let prior = fixture.root.appendingPathComponent("prior")
        try FileManager.default.moveItem(at: fixture.library.directory, to: prior)
        try FileManager.default.createDirectory(at: fixture.library.directory, withIntermediateDirectories: true)
        try Data("replacement root".utf8).write(to: fixture.target)
        let result = PluginFileOperationRecovery(journal: fixture.journal).resumePending(modelContext: fixture.context)
        #expect(result.completed == 0 && result.deferred == 1)
        #expect(try fixture.value() == "replacement root")
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
    }

    @Test("Preparation refuses unsafe paths and symbolic-link images without changing live files")
    func unsafePreparationIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        #expect(throws: (any Error).self) {
            try fixture.journal.prepare(storeIdentity: "store", pluginIDs: [], changes: [
                .init(root: .library, name: "../outside", replacement: nil)
            ])
        }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.target)
        #expect(throws: (any Error).self) { try PluginFileImage.capture(link) }
        let invalid = PluginFileImage(isDirectory: true, directories: [], files: ["../escape": Data()])
        #expect(throws: (any Error).self) { try invalid.validated() }
        #expect(try fixture.value() == "old definition")
    }

    @Test("A directory image preserves nested bytes and refuses a second pending operation")
    func literalDirectoryImageAndSerialization() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let image = PluginFileImage(isDirectory: true, directories: ["icons"], files: ["manifest.json": Data("manifest".utf8), "icons/image.png": Data([1, 2, 3])])
        let prepared = try fixture.journal.prepare(storeIdentity: #require(PersistentStoreIdentity.current(for: fixture.context)),
            pluginIDs: ["example"], changes: [.init(root: .library, name: "package", replacement: image)])
        try fixture.journal.apply(prepared, forward: true)
        #expect(try PluginFileImage.capture(fixture.library.directory.appendingPathComponent("package")) == image)
        #expect(throws: PluginFileOperationJournal.Failure.pendingOperation) { try fixture.prepare() }
        try fixture.journal.apply(prepared, forward: false)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.directory.appendingPathComponent("package").path))
    }

    @MainActor
    struct Fixture {
        let root: URL
        let store: URL
        let library: CapabilityLibrary
        let journal: PluginFileOperationJournal
        let container: ModelContainer
        var context: ModelContext { container.mainContext }
        var target: URL { library.directory.appendingPathComponent("example.json") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-file-recovery-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = root.appendingPathComponent("store.sqlite")
            library = CapabilityLibrary(directory: root.appendingPathComponent("Library"))
            try library.ensureDirectoryExists()
            journal = PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore(directory: root.appendingPathComponent("Approvals")))
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: ModelConfiguration(url: store))
            container.mainContext.autosaveEnabled = false
            try container.mainContext.save()
            try Data("old definition".utf8).write(to: target)
        }
        func prepare() throws -> PluginFileOperationJournal.Prepared {
            try journal.prepare(storeIdentity: #require(PersistentStoreIdentity.current(for: context)), pluginIDs: ["example"],
                changes: [.init(root: .library, name: "example.json", replacement: PluginFileImage(isDirectory: false, directories: [], files: ["": Data("new definition".utf8)]))])
        }
        func commit(_ prepared: PluginFileOperationJournal.Prepared, workspaceIDs: [UUID] = []) throws {
            let outcome = PluginOperationCommit.save(id: prepared.id, kind: .approval, pluginIDs: ["example"],
                workspaceIDs: workspaceIDs, manifestDigest: prepared.digest, modelContext: context)
            guard case .committed = outcome else { Issue.record("Fixture did not commit"); return }
        }
        func reopen() throws -> ModelContainer {
            try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: ModelConfiguration(url: store))
        }
        func value() throws -> String { try String(contentsOf: target, encoding: .utf8) }
        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }
}
