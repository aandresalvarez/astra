import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Task read-state persistence")
struct TaskReadStateServiceTests {
    private struct ExpectedSaveFailure: Error {}

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-read-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeUnreadTask(in context: ModelContext) throws -> AgentTask {
        let task = AgentTask(title: "Unread", goal: "Open me")
        task.unreadAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(task)
        try context.save()
        return task
    }

    @Test("Marking read clears unreadAt before persistence runs")
    func markingReadClearsUnreadBeforePersistence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = try makeUnreadTask(in: context)

        var unreadAtPersistEntry: Date?
        var persistCount = 0
        let service = TaskReadStateService(modelContext: context) { task, context in
            unreadAtPersistEntry = task.unreadAt
            persistCount += 1
            try context.save()
        }
        service.markRead(task)

        #expect(persistCount == 1)
        #expect(unreadAtPersistEntry == nil)
        #expect(task.unreadAt == nil)
        #expect(!task.shouldShowUnread)
    }

    @Test("Marking read survives a fresh ModelContext")
    func markingReadSurvivesFreshContext() throws {
        let container = try makeContainer()
        let task = try makeUnreadTask(in: container.mainContext)
        let taskID = task.id

        TaskReadStateService(modelContext: container.mainContext) { _, context in
            try context.save()
        }.markRead(task)

        let freshContext = ModelContext(container)
        let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        let stored = try #require(try freshContext.fetch(descriptor).first)
        #expect(stored.unreadAt == nil)
    }

    @Test("A failed persist keeps the task read and does not throw")
    func failedPersistKeepsTaskRead() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = try makeUnreadTask(in: context)

        let service = TaskReadStateService(modelContext: context) { _, _ in
            throw ExpectedSaveFailure()
        }
        service.markRead(task)

        #expect(task.unreadAt == nil)
        #expect(!task.shouldShowUnread)
    }

    /// Runs the real `persist` closure — no injected seam — because argument and
    /// ordering mistakes inside it (exporting with `workspace: nil`, scheduling
    /// only on failure) are invisible to a substring scan of the source file.
    ///
    /// The debounced export is drained through the termination flush rather than
    /// slept on, so the 600 ms timer cannot outlive the test and touch a
    /// directory this test has already deleted.
    @Test("Production read-state writer saves durably and defers the workspace mirror")
    func productionReadStateWriterDefersMirror() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Read state", primaryPath: root.path)
        context.insert(workspace)
        let task = try makeUnreadTask(in: context)
        task.workspace = workspace
        try context.save()
        let taskID = task.id
        let mirrorURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))

        TaskReadStateService(modelContext: context).markRead(task)

        // Deferred: opening a task must not pay for a whole-workspace export.
        #expect(!FileManager.default.fileExists(atPath: mirrorURL.path))
        // Durable anyway: the SwiftData write is not deferred with it.
        let freshContext = ModelContext(container)
        let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        let stored = try #require(try freshContext.fetch(descriptor).first)
        #expect(stored.unreadAt == nil)

        // Scheduled, not dropped: the mirror the importer reads back has to
        // learn about the read within the debounce window.
        let flushed = WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context)
        #expect(flushed >= 1)
        #expect(FileManager.default.fileExists(atPath: mirrorURL.path))
        let mirrored = try JSONSerialization.jsonObject(with: Data(contentsOf: mirrorURL)) as? [String: Any]
        let mirroredTasks = mirrored?["tasks"] as? [[String: Any]] ?? []
        let mirroredTask = mirroredTasks.first { $0["id"] as? String == taskID.uuidString }
        // `false`, not `!= true`: a missing task fails this too.
        #expect(mirroredTask?.keys.contains("unreadAt") == false)
    }

    @Test("Content view delegates read-state persistence and keeps its telemetry phase")
    func contentViewDelegatesReadStatePersistence() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func markTaskRead("))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\n    private func "))
        let body = tail[..<end.lowerBound]

        #expect(body.contains("mark_task_read_persistence"))
        #expect(body.contains("taskReadStateService.markRead"))
        #expect(!body.contains("WorkspacePersistenceCoordinator"))
    }
}
