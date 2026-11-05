import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Publication evidence repeat work")
@MainActor
struct TaskPublicationDecisionEvidenceWorkTests {
    @Test("Appended unrelated failures scan only new rows and backdating still forces a full search", arguments: [false, true])
    func appendedFailuresDoNotRepeatLegacySearch(actionable: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("history.store")))
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = AgentTask(title: "Synthetic", goal: "Fix the bug and create a pull request")
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        @discardableResult
        func insert(_ type: String, _ payload: String, _ time: Double) -> TaskEvent {
            let event = TaskEvent(task: task, type: type, payload: payload, run: run)
            event.timestamp = Date(timeIntervalSince1970: time)
            context.insert(event)
            return event
        }
        insert("tool.use", actionable ? "gh pr create --draft" : "git status", 1)
        insert("tool.result.failed", "permission denied", 2)
        insert("tool.use", "git status", 3)
        for index in 0..<1_500 { insert("tool.result.failed", "unrelated failure", Double(10 + index)) }
        let start = insert("user.message", "ordinary", 10_000)
        try context.save()
        let store = TaskThreadHistoryStore(container: container)
        var cursor = TaskThreadEventCursor(timestamp: start.timestamp, id: start.id, ownerID: task.persistentModelID)
        func read() async throws -> TaskThreadHistoryTailPage {
            try await store.tailPage(taskID: task.id, ownerID: task.persistentModelID, since: cursor)
        }
        func verify(_ events: [TaskEventSnapshot]) throws {
            let fresh = ModelContext(container)
            let uncached = try TaskPublicationDecisionEvidenceReader.latest(ownerID: task.persistentModelID,
                runID: run.id, in: fresh)
            #expect(Set(events) == Set(uncached))
        }
        try verify(try await read().publicationEvents)
        let primed = await store.publicationWorkForTesting()
        for index in 0..<12 {
            let time = Double(10_010 + index * 2)
            insert("tool.use", "git status", time)
            let failure = insert("tool.result.failed", "unrelated failure", time + 1)
            try context.save()
            try verify(try await read().publicationEvents)
            cursor = TaskThreadEventCursor(timestamp: failure.timestamp, id: failure.id, ownerID: task.persistentModelID)
        }
        let appended = await store.publicationWorkForTesting()
        #expect(appended.failureRowsScanned - primed.failureRowsScanned == 12)
        #expect(appended.toolUseLookups - primed.toolUseLookups == 12)
        let backdated = insert("tool.result.failed", "gh pr create: backdated failure", 1_000.5)
        try context.save()
        let changed = try await read()
        try verify(changed.publicationEvents)
        #expect(changed.publicationEvents.contains { $0.id == backdated.id })
        let rescanned = await store.publicationWorkForTesting()
        #expect(rescanned.failureRowsScanned > appended.failureRowsScanned + 12)
    }

    @Test("Ordinary tail messages do not rescan failures, with or without PR intent", arguments: [false, true])
    func ordinaryAppendsDoNotRepeatLegacySearch(prIntent: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("history.store"))
        )
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = AgentTask(title: "Synthetic task", goal: prIntent ? "Fix the bug and create a pull request" : "Describe a synthetic table")
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        @discardableResult
        func event(_ type: String, _ payload: String, at time: Double) -> TaskEvent {
            let event = TaskEvent(task: task, type: type, payload: payload, run: run)
            event.timestamp = Date(timeIntervalSince1970: time)
            context.insert(event)
            return event
        }
        event("tool.use", "gh pr create --draft", at: 1)
        let originalFailure = event("tool.result.failed", "permission denied", at: 2)
        event("tool.use", "git status", at: 3)
        var failures: [TaskEvent] = []
        for index in 0..<1_500 {
            failures.append(event("tool.result.failed", "unrelated command failed", at: Double(10 + index)))
        }
        let firstTail = event("user.message", "ordinary", at: 10_000)
        let foreignTask = AgentTask(title: "Foreign owner", goal: "Unrelated")
        foreignTask.id = task.id
        context.insert(foreignTask)
        let foreignFailure = TaskEvent(task: foreignTask, type: "tool.result.failed", payload: "foreign failure")
        context.insert(foreignFailure)
        try context.save()
        let store = TaskThreadHistoryStore(container: container)
        func tail(_ cursor: TaskThreadEventCursor, invalidation: Int = 0) async throws -> TaskThreadHistoryTailPage {
            try await store.tailPage(taskID: task.id, ownerID: task.persistentModelID, since: cursor,
                                     historyInvalidation: invalidation)
        }
        var cursor = TaskThreadEventCursor(timestamp: firstTail.timestamp, id: firstTail.id, ownerID: task.persistentModelID)
        let first = try await tail(cursor)
        let primed = await store.publicationWorkForTesting()
        if prIntent {
            #expect(first.publicationEvents.contains { $0.id == originalFailure.id })
            #expect(primed.failureRowsScanned >= 1_500)
        } else {
            #expect(first.publicationEvents.isEmpty)
            #expect(primed.failureRowsScanned == 0)
            #expect(primed.toolUseLookups == 0)
        }
        for index in 0..<12 {
            let ordinary = event(index == 6 ? "tool.use" : "user.message", "ordinary", at: Double(10_001 + index))
            try context.save()
            let page = try await tail(cursor)
            #expect(page.events.count <= 2)
            #expect(page.publicationEvents.count <= 6)
            cursor = TaskThreadEventCursor(timestamp: ordinary.timestamp, id: ordinary.id, ownerID: task.persistentModelID)
        }
        let repeated = await store.publicationWorkForTesting()
        #expect(repeated.failureRowsScanned == primed.failureRowsScanned)
        #expect(repeated.toolUseLookups == primed.toolUseLookups)
        // A different persistent owner can share the portable UUID. Its edit
        // must not make the next ordinary append rescan this run's failures.
        foreignFailure.payload = "foreign failure edited"
        try context.save()
        let afterForeign = event("user.message", "ordinary", at: 10_020)
        try context.save()
        _ = try await tail(cursor)
        cursor = TaskThreadEventCursor(timestamp: afterForeign.timestamp, id: afterForeign.id, ownerID: task.persistentModelID)
        let foreignWork = await store.publicationWorkForTesting()
        #expect(foreignWork.failureRowsScanned == repeated.failureRowsScanned)
        #expect(foreignWork.toolUseLookups == repeated.toolUseLookups)
        if prIntent {
            #expect(repeated.cacheHits >= primed.cacheHits + 12)
            // This is not the newest failed row or selected evidence. Its
            // same-count edit must invalidate through the context save boundary.
            failures[500].payload = "gh pr create failed"
            try context.save()
            let edited = try await tail(cursor)
            #expect(edited.publicationEvents.contains { $0.id == failures[500].id })
            let afterEdit = await store.publicationWorkForTesting()
            #expect(afterEdit.failureRowsScanned > repeated.failureRowsScanned)
            _ = try await tail(cursor, invalidation: 1)
            let afterInvalidation = await store.publicationWorkForTesting()
            #expect(afterInvalidation.failureRowsScanned > afterEdit.failureRowsScanned)
        }
        // Typed requests remain authoritative after PR wording is removed.
        task.goal = "Describe a synthetic table"
        let requested = event("git.publish.requested", TaskEvent.payloadString(TaskRequiredExternalOutcomeRequest(
            kind: .githubPullRequest, runID: run.id, message: "Review the synthetic publication"
        )), at: 20_000)
        try context.save()
        let typed = try await tail(cursor)
        #expect(typed.publicationEvents.contains { $0.id == requested.id })
        let receipt = event("git.publish.receipt", "{}", at: 20_001)
        try context.save()
        let resolved = try await tail(cursor)
        #expect(resolved.publicationEvents.contains { $0.id == receipt.id })
        let records = resolved.publicationEvents.map {
            TaskOutcomeEventRecord(id: $0.id, runID: $0.runID, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
        }
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task, targetRunID: run.id, events: records
        ) == nil)
    }
}
