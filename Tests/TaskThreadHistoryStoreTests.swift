import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// `TaskThreadHistoryStore` builds a fresh `ModelContext` per read from the
/// container it was handed, so it only ever sees rows that were saved. Every
/// fixture here saves explicitly; production covers the same gap by flushing
/// the main context before each read.
@Suite("Task thread history store")
struct TaskThreadHistoryStoreTests {
    @MainActor
    private func fixture(
        runs: Int,
        events: Int
    ) throws -> (container: ModelContainer, taskID: UUID) {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Background history", goal: "Read off the main actor")
        task.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(task)
        for index in 0..<runs {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index * 10))
            context.insert(run)
        }
        for index in 0..<events {
            let event = TaskEvent(task: task, type: "system.info", payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()
        return (container, task.id)
    }

    @Test("Background store page matches the main-actor reader")
    func backgroundPageMatchesMainActorReader() async throws {
        let (container, taskID) = try await fixture(runs: 75, events: 1_300)
        let store = TaskThreadHistoryStore(container: container)

        let page = try await store.initialPage(taskID: taskID)
        let reference = try await MainActor.run {
            try TaskThreadHistoryReader.initialPage(
                taskID: taskID,
                modelContext: container.mainContext
            )
        }

        #expect(page.runs.map(\.id) == reference.runs.map(\.id))
        #expect(page.events.map(\.id) == reference.events.map(\.id))
        #expect(Set(page.stateAnchors.map(\.id)) == Set(reference.stateAnchors.map(\.id)))
        #expect(page.totalRunCount == reference.totalRunCount)
        #expect(page.totalEventCount == reference.totalEventCount)
        #expect(page.cursor == reference.cursor)
    }

    @Test("History pages read from a non-main task")
    func pagesReadFromDetachedTask() async throws {
        let (container, taskID) = try await fixture(runs: 3, events: 40)
        let store = TaskThreadHistoryStore(container: container)

        let page = try await Task.detached {
            try await store.initialPage(taskID: taskID)
        }.value

        #expect(page.totalEventCount == 40)
        #expect(page.totalRunCount == 3)
        #expect(page.events.count == 40)
    }

    @Test("Tail pages cross the actor boundary with the same cursor semantics")
    func tailPageMatchesMainActorReader() async throws {
        let (container, taskID) = try await fixture(runs: 2, events: 40)
        let store = TaskThreadHistoryStore(container: container)
        let page = try await store.initialPage(taskID: taskID)
        let newest = try #require(page.events.first)
        let cursor = TaskThreadEventCursor(timestamp: newest.timestamp, id: newest.id)

        let tail = try await store.tailPage(taskID: taskID, since: cursor)
        let reference = try await MainActor.run {
            try TaskThreadHistoryReader.tailPage(
                taskID: taskID,
                since: cursor,
                modelContext: container.mainContext
            )
        }

        #expect(tail.events.map(\.id) == reference.events.map(\.id))
        #expect(tail.events.map(\.id) == [newest.id])
        #expect(tail.totalEventCount == reference.totalEventCount)
        #expect(tail.totalRunCount == reference.totalRunCount)
        #expect(tail.overflowed == reference.overflowed)
    }

    @Test("Previous page paging is stable across the actor boundary")
    func previousPagePagingIsStable() async throws {
        let (container, taskID) = try await fixture(runs: 0, events: 1_500)
        let store = TaskThreadHistoryStore(container: container)

        let first = try await store.initialPage(taskID: taskID, eventPageSize: 500)
        #expect(first.events.count == 500)
        #expect(first.cursor.hasEarlierEvents)

        let second = try await store.previousPage(
            taskID: taskID,
            before: first.cursor,
            eventPageSize: 500
        )
        let third = try await store.previousPage(
            taskID: taskID,
            before: second.cursor,
            eventPageSize: 500
        )

        let walked = first.events + second.events + third.events
        #expect(walked.count == 1_500)
        #expect(Set(walked.map(\.id)).count == 1_500)
        #expect(!third.cursor.hasEarlierEvents)
    }

    @Test("A fresh context per read observes a payload mutated after the first read")
    func freshContextPerReadSeesMutatedPayloads() async throws {
        let (container, taskID) = try await fixture(runs: 0, events: 1)
        let store = TaskThreadHistoryStore(container: container)
        #expect(try await store.initialPage(taskID: taskID).events.first?.payload == "event 0")

        try await MainActor.run {
            let context = container.mainContext
            let event = try #require(
                try context.fetch(FetchDescriptor<TaskEvent>()).first
            )
            event.payload = "event 0 continued"
            try context.save()
        }

        // A store that reused one context would still be serving the row it
        // materialized above.
        let page = try await store.initialPage(taskID: taskID)
        #expect(page.events.first?.payload == "event 0 continued")
    }
}
