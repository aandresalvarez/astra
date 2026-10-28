import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Files sessions use persisted ownership", .serialized)
@MainActor
struct ShelfFilesOwnershipTests {
    @Test("Pinned copies keep documents and unsaved edits separate; releasing one preserves the other")
    func pinnedCopies() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let store = ShelfMarkdownSessionStore()
        let a = f.session(store, task: f.a, pinned: true)
        a.load(f.fileA)
        a.updateSelectedContent("Unsaved A")
        let b = f.session(store, task: f.b, pinned: true)
        #expect(a !== b && b.documents.isEmpty)
        b.load(f.fileB)
        #expect(f.session(store, task: f.a, pinned: true) === a)
        #expect(a.content == "Unsaved A" && a.isSelectedDocumentDirty)
        store.releaseSession(for: f.a.id, ownerID: f.a.persistentModelID)
        #expect(f.session(store, task: f.b, pinned: true) === b)
        #expect(b.fileURL == f.fileB)
        #expect(f.session(store, task: f.a, pinned: true).documents.isEmpty)
    }

    @Test("Workspace tabs stay shared intentionally while selection follows the persisted task")
    func sharedSelection() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let store = ShelfMarkdownSessionStore()
        let a = f.session(store, task: f.a, pinned: false)
        a.load(f.fileA)
        let b = f.session(store, task: f.b, pinned: false)
        #expect(a === b && b.selectedDocument == nil)
        b.load(f.fileB)
        #expect(f.session(store, task: f.a, pinned: false).fileURL == f.fileA)
        #expect(a.documents.count == 2)
        let copy = Workspace(name: "Imported workspace", primaryPath: f.root.path)
        copy.id = f.workspace.id
        f.container.mainContext.insert(copy)
        try f.container.mainContext.save()
        let separate = store.session(for: nil, workspaceID: copy.id, pinnedToTask: false,
            workspaceOwnerID: copy.persistentModelID)
        #expect(separate !== a && separate.documents.isEmpty)
        store.releaseSession(forWorkspaceID: copy.id, ownerID: copy.persistentModelID)
        #expect(f.session(store, task: f.a, pinned: false) === a)
    }

    @Test("Switching same-UUID owners cancels a pending preview before it can publish")
    func pendingPreview() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let loader = SuspendedFilesLoader()
        let session = ShelfMarkdownSession(documentLoader: loader)
        session.bindToTask(f.a.id, ownerID: f.a.persistentModelID)
        let pending = Task { await session.loadAsync(f.fileA) }
        await loader.waitUntilStarted()
        session.bindToTask(f.b.id, ownerID: f.b.persistentModelID)
        await loader.finish()
        #expect(await !pending.value)
        #expect(session.documents.isEmpty && session.selectedDocument == nil && !session.isLoadingDocument)
    }

    @Test("A queued preview cannot start after switching to another copy")
    func queuedPreview() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let session = ShelfMarkdownSession()
        session.bindToTask(f.a.id, ownerID: f.a.persistentModelID)
        let request = session.prepareLoad(f.fileA)
        let pending = Task { await session.load(request) }
        session.bindToTask(f.b.id, ownerID: f.b.persistentModelID)
        #expect(await !pending.value)
        #expect(session.documents.isEmpty && session.selectedDocument == nil)
        // Returning to A does not make the old queued request current again.
        session.bindToTask(f.a.id, ownerID: f.a.persistentModelID)
        #expect(await !session.load(request))
        #expect(await session.load(session.prepareLoad(f.fileA)))
        #expect(session.fileURL == f.fileA)
    }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let root: URL
        let workspace: Workspace
        let a: AgentTask
        let b: AgentTask
        var fileA: URL { root.appendingPathComponent("a.md") }
        var fileB: URL { root.appendingPathComponent("b.md") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("files-owners-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            container.mainContext.autosaveEnabled = false
            workspace = Workspace(name: "Files QA", primaryPath: root.path)
            a = AgentTask(title: "Original", goal: "A", workspace: workspace)
            b = AgentTask(title: "Imported", goal: "B", workspace: workspace)
            b.id = a.id
            container.mainContext.insert(workspace)
            container.mainContext.insert(a); container.mainContext.insert(b)
            try container.mainContext.save()
            try "A".write(to: fileA, atomically: true, encoding: .utf8)
            try "B".write(to: fileB, atomically: true, encoding: .utf8)
        }
        func session(_ store: ShelfMarkdownSessionStore, task: AgentTask, pinned: Bool) -> ShelfMarkdownSession {
            store.session(for: task.id, workspaceID: workspace.id, pinnedToTask: pinned,
                taskOwnerID: task.persistentModelID, workspaceOwnerID: workspace.persistentModelID)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor SuspendedFilesLoader: ShelfDocumentLoading {
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func loadDocument(at url: URL) async -> ShelfMarkdownDocument {
        await withCheckedContinuation { continuation in
            release = continuation
            started?.resume(); started = nil
        }
        return ShelfMarkdownSession.makeDocument(for: url)
    }
    func waitUntilStarted() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { release?.resume(); release = nil }
}
