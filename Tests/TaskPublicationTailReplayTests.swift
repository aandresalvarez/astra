import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// Optional replay of the review's growing-failure fixture. Timings are
/// observations only; deterministic work assertions live in the work suite.
@Suite("Publication tail replay", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_MEASURE_PUBLICATION_TAIL"] == "1",
                "Set ASTRA_MEASURE_PUBLICATION_TAIL=1 for the isolated tail replay"))
@MainActor
struct TaskPublicationTailReplayTests {
    @Test func failureHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: Workspace.self, AgentTask.self, TaskRun.self, TaskEvent.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("history.store")))
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = AgentTask(title: "Transcript", goal: "Describe a synthetic table")
        task.status = .running
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let use = TaskEvent(task: task, type: "tool.use", payload: "git status", run: run)
        use.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(use)
        var previous = 0
        var cursor: TaskThreadEventCursor?
        for size in [0, 100, 750, 1_500] {
            for index in previous..<size {
                let failed = TaskEvent(task: task, type: "tool.result.failed", payload: "unrelated command failed", run: run)
                failed.timestamp = Date(timeIntervalSince1970: Double(index + 2))
                context.insert(failed)
            }
            previous = size
            let tail = TaskEvent(task: task, type: "user.message", payload: "synthetic")
            tail.timestamp = Date(timeIntervalSince1970: Double(10_000 + size))
            context.insert(tail)
            try context.save()
            let current = TaskThreadEventCursor(timestamp: tail.timestamp, id: tail.id, ownerID: task.persistentModelID)
            cursor = current
            var milliseconds: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                try autoreleasepool {
                    let isolated = ModelContext(container)
                    isolated.autosaveEnabled = false
                    let page = try TaskThreadHistoryReader.tailPage(taskID: task.id, ownerID: task.persistentModelID,
                                                                   since: current, modelContext: isolated)
                    #expect(page.events.count == 1)
                    #expect(page.publicationEvents.isEmpty)
                }
                milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            print("[publication-tail] intent=false failures=\(size) rows=1 ms=\(milliseconds)")
        }
        task.goal = "Fix the bug and create a pull request"
        try context.save()
        let store = TaskThreadHistoryStore(container: container)
        let current = try #require(cursor)
        for index in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await store.tailPage(taskID: task.id, ownerID: task.persistentModelID, since: current)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let work = await store.publicationWorkForTesting()
            print("[publication-tail] intent=true failures=1500 read=\(index) ms=\(elapsed) scanned=\(work.failureRowsScanned) uses=\(work.toolUseLookups) hits=\(work.cacheHits)")
        }
    }
}
