import Foundation
import SwiftData
import Testing
import ASTRAModels
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

    @Test("Production read-state writer defers the workspace mirror")
    func productionReadStateWriterDefersMirror() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Tasks/TaskReadStateService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("saveWithoutAutoExportOrThrow"))
        #expect(source.contains("scheduleAutoExport"))
        #expect(!source.contains("saveAndAutoExportOrThrow"))
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
