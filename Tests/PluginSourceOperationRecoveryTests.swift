import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Source provenance commit proof", .serialized)
struct PluginSourceOperationRecoveryTests {
    enum Failure: Error { case finish }

    @Test("An uncommitted same-bytes import keeps its source after a real reopen")
    func uncommittedSameBytesKeepOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let (source, file) = try fixture.prepare(after: nil)
        try fixture.files.apply(file, forward: true)
        try fixture.store.recordProvenance(pluginID: "other", sourceID: "unrelated", digest: "newer")
        let reopened = try fixture.disk.reopen()
        let result = PluginFileOperationRecovery(journal: fixture.files).resumePending(modelContext: reopened.mainContext,
            metadata: fixture.sources.handler(modelContext: reopened.mainContext))
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(fixture.store.provenance()["example"] == fixture.original)
        #expect(fixture.store.provenance()["other"]?.sourceID == "unrelated")
        #expect(try fixture.sources.pendingIDs().isEmpty)
        #expect(try fixture.files.pendingIDs().isEmpty)
        #expect(try PluginOperationCommit.read(source.id, container: reopened) == nil)
    }

    @Test("A committed same-bytes import publishes provenance before mirrors and survives a pending copy")
    func committedOwnershipPrecedesMirrors() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let workspace = Workspace(name: "Affected", primaryPath: "")
        fixture.disk.context.insert(workspace)
        try fixture.disk.context.save()
        let (source, file) = try fixture.prepare(after: nil)
        try fixture.commit(file, workspaceIDs: [workspace.id])
        try fixture.store.recordProvenance(pluginID: "other", sourceID: "independent", digest: "changed")
        var sawNewOwner = false
        let held = PluginFileOperationRecovery(journal: fixture.files).resumePending(modelContext: fixture.disk.context,
            export: { _, _ in sawNewOwner = fixture.store.provenance()["example"] == nil; return false },
            metadata: fixture.sources.handler(modelContext: fixture.disk.context))
        #expect(sawNewOwner && held.deferred == 1 && held.completed == 0)
        #expect(try fixture.sources.pendingIDs() == [source.id])
        #expect(try PluginOperationCommit.read(source.id, container: fixture.disk.container)?.completedAt == nil)
        let reopened = try fixture.disk.reopen()
        let finished = PluginFileOperationRecovery(journal: fixture.files).resumePending(modelContext: reopened.mainContext,
            export: { _, _ in true }, metadata: fixture.sources.handler(modelContext: reopened.mainContext))
        #expect(finished.completed == 1 && finished.deferred == 0)
        #expect(fixture.store.provenance()["example"] == nil)
        #expect(fixture.store.provenance()["other"]?.sourceID == "independent")
        #expect(try fixture.sources.pendingIDs().isEmpty)
    }

    @Test("Metadata-linked manifests require the new reader and a metadata recovery handler")
    func unsupportedRecoveryNeverCompletes() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let (_, file) = try fixture.prepare(after: nil)
        #expect(file.manifest.version == 2)
        try fixture.commit(file)
        let result = PluginFileOperationRecovery(journal: fixture.files).resumePending(modelContext: fixture.disk.context)
        #expect(result.completed == 0 && result.deferred == 1)
        #expect(fixture.store.provenance()["example"] == fixture.original)
        #expect(try PluginOperationCommit.read(file.id, container: fixture.disk.container)?.completedAt == nil)
        #expect(try fixture.sources.pendingIDs() == [file.id])
    }

    @Test("Changed ownership is never overwritten by an older prepared operation")
    func laterOwnershipIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let (_, file) = try fixture.prepare(after: nil)
        try fixture.commit(file)
        try fixture.store.recordProvenance(pluginID: "example", sourceID: "later", digest: "different")
        let result = PluginFileOperationRecovery(journal: fixture.files).resumePending(modelContext: fixture.disk.context,
            metadata: fixture.sources.handler(modelContext: fixture.disk.context))
        #expect(result.completed == 0 && result.deferred == 1)
        #expect(fixture.store.provenance()["example"]?.sourceID == "later")
        #expect(try fixture.sources.pendingIDs() == [file.id])
    }

    @Test("An unreadable ownership file is never replaced by an empty or partial map")
    func corruptOwnershipIsNotEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let (_, file) = try fixture.prepare(after: nil)
        try fixture.commit(file)
        let url = fixture.store.root.appendingPathComponent("provenance.json")
        let original = try Data(contentsOf: url)
        let damaged = Data("not-json".utf8)
        try damaged.write(to: url, options: .atomic)
        let recovery = PluginFileOperationRecovery(journal: fixture.files)
        let held = recovery.resumePending(modelContext: fixture.disk.context,
            metadata: fixture.sources.handler(modelContext: fixture.disk.context))
        #expect(held.deferred == 1)
        #expect(try Data(contentsOf: url) == damaged)
        #expect(try PluginOperationCommit.read(file.id, container: fixture.disk.container)?.completedAt == nil)
        try original.write(to: url, options: .atomic)
        let retry = recovery.resumePending(modelContext: fixture.disk.context,
            metadata: fixture.sources.handler(modelContext: fixture.disk.context))
        #expect(retry.completed == 1 && fixture.store.provenance()["example"] == nil)
    }

    @Test("Metadata garbage after confirmed completion cannot overwrite a later source edit")
    func completedOrphanOnlyGetsRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let (_, file) = try fixture.prepare(after: nil)
        try fixture.commit(file)
        let normal = fixture.sources.handler(modelContext: fixture.disk.context)
        let interrupted = PluginFileOperationRecovery.MetadataHandler(reconcile: normal.reconcile, finish: { _, _ in throw Failure.finish })
        let result = PluginFileOperationRecovery(journal: fixture.files).resumePending(modelContext: fixture.disk.context, metadata: interrupted)
        #expect(result.deferred == 1 && result.completed == 0)
        #expect(try fixture.files.pendingIDs().isEmpty)
        #expect(try PluginOperationCommit.read(file.id, container: fixture.disk.container)?.completedAt != nil)
        try fixture.store.recordProvenance(pluginID: "example", sourceID: "later", digest: "new")
        let retry = fixture.sources.resumeOrphans(modelContext: fixture.disk.context, files: fixture.files)
        #expect(retry.completed == 1 && retry.deferred == 0)
        #expect(fixture.store.provenance()["example"]?.sourceID == "later")
        #expect(try fixture.sources.pendingIDs().isEmpty)
    }

    @Test("An orphan before file preparation needs a matching store and preserves unrelated records")
    func orphanBeforeFiles() throws {
        let fixture = try Fixture()
        defer { fixture.disk.removeFiles() }
        let source = try fixture.sources.prepare(pluginID: "example", after: nil, modelContext: fixture.disk.context)
        let wrong = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let held = fixture.sources.resumeOrphans(modelContext: wrong.mainContext, files: fixture.files)
        #expect(held.deferred == 1)
        #expect(try fixture.sources.pendingIDs() == [source.id])
        try fixture.store.recordProvenance(pluginID: "other", sourceID: "independent", digest: "new")
        let reopened = try fixture.disk.reopen()
        let result = fixture.sources.resumeOrphans(modelContext: reopened.mainContext, files: fixture.files)
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(fixture.store.provenance()["example"] == fixture.original)
        #expect(fixture.store.provenance()["other"]?.sourceID == "independent")
    }

    @MainActor
    struct Fixture {
        let disk: PluginFileOperationRecoveryTests.Fixture
        let store: PluginSourceStore
        let sources: PluginSourceOperationJournal
        let files: PluginFileOperationJournal
        let original = PluginSourceStore.Provenance(sourceID: "original", digest: "same-bytes")
        init() throws {
            disk = try PluginFileOperationRecoveryTests.Fixture()
            store = PluginSourceStore(root: disk.root.appendingPathComponent("Sources"))
            sources = PluginSourceOperationJournal(store: store)
            files = disk.journal
            try store.recordProvenance(pluginID: "example", sourceID: original.sourceID, digest: original.digest)
        }
        func prepare(after: PluginSourceStore.Provenance?) throws -> (PluginSourceOperationJournal.Prepared, PluginFileOperationJournal.Prepared) {
            let source = try sources.prepare(pluginID: "example", after: after, modelContext: disk.context)
            let file = try files.prepare(id: source.id, storeIdentity: #require(PersistentStoreIdentity.current(for: disk.context)),
                pluginIDs: ["example"], changes: [.init(root: .library, name: "example.json", replacement:
                    PluginFileImage(isDirectory: false, directories: [], files: ["": Data("old definition".utf8)]))],
                linkedMetadataDigest: source.digest)
            return (source, file)
        }
        func commit(_ file: PluginFileOperationJournal.Prepared, workspaceIDs: [UUID] = []) throws {
            let outcome = PluginOperationCommit.save(id: file.id, kind: .update, pluginIDs: ["example"], workspaceIDs: workspaceIDs,
                manifestDigest: file.digest, modelContext: disk.context)
            guard case .committed = outcome else { Issue.record("Fixture save was not committed"); return }
        }
    }
}
