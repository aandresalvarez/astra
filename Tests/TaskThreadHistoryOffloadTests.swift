import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// Covers the view model once the transcript read moved to
/// `TaskThreadHistoryStore`. The store reads the persistent file through its
/// own context, so anything these fixtures leave unsaved is invisible to it
/// unless the view model flushes the main context first.
@Suite("Task thread history offload")
@MainActor
struct TaskThreadHistoryOffloadTests {
    private func fixture() throws -> (ModelContainer, ModelContext, AgentTask) {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Offloaded history", goal: "Keep the main actor free")
        task.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(task)
        return (container, context, task)
    }

    @Test("Storage-backed reset applies the page without reading on the main actor")
    func resetAppliesThePageAsynchronously() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<25 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)

        // The read used to run inside `reset`. What the main actor gets back
        // now is the placeholder.
        #expect(viewModel.historyReadCountForTesting == 0)
        #expect(viewModel.snapshot?.sortedEvents.isEmpty == true)

        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 1)
        #expect(viewModel.snapshot?.sortedEvents.count == 25)
        #expect(viewModel.appliedSnapshotTaskID == task.id)
        #expect(viewModel.historyLoadState == .idle)
    }

    @Test("Unsaved streaming deltas still reach the transcript")
    func unsavedStreamingDeltasReachTheTranscript() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        context.insert(run)
        let recorder = AgentEventRecordingState(maxCoalescedPayloadLength: 1_000)
        recorder.appendConversationChunk(
            eventType: TaskEventTypes.Conversation.agentResponse,
            text: "first ",
            to: task,
            run: run,
            modelContext: context
        )
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["first "])

        // Streaming coalesces into the row in the main context and never saves,
        // so without the view model's pre-read flush the background read would
        // keep serving "first ".
        recorder.appendConversationChunk(
            eventType: TaskEventTypes.Conversation.agentResponse,
            text: "second",
            to: task,
            run: run,
            modelContext: context
        )
        let newEvent = TaskEvent(task: task, type: "user.message", payload: "unsaved insert")
        newEvent.timestamp = Date()
        TaskEventInsertionService.insert(newEvent, into: context)
        #expect(context.hasChanges)

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        let payloads = Set(viewModel.snapshot?.sortedEvents.map(\.payload) ?? [])
        #expect(payloads == ["first second", "unsaved insert"])
    }

    @Test("A refresh storm coalesces to a bounded number of history reads")
    func refreshStormStaysSingleFlight() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<50 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.historyReadCountForTesting == 1)

        // Making the read async removed the back-pressure the synchronous block
        // used to provide, so the worker must hold exactly one pending slot.
        for _ in 0..<200 {
            task.updatedAt = task.updatedAt.addingTimeInterval(1)
            viewModel.refreshSnapshot(for: task)
        }
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyReadCountForTesting <= 3)
        #expect(viewModel.snapshot?.sortedEvents.count == 50)
    }

    @Test("A task switch during an in-flight read never applies the old task")
    func taskSwitchDuringInFlightReadDiscardsTheOldPage() async throws {
        let (container, context, firstTask) = try fixture()
        defer { _ = container }
        for index in 0..<40 {
            let event = TaskEvent(task: firstTask, type: "user.message", payload: "old task \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(event)
        }
        let secondTask = AgentTask(title: "New selection", goal: "Stay selected")
        secondTask.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(secondTask)
        let ownEvent = TaskEvent(task: secondTask, type: "user.message", payload: "new task only")
        ownEvent.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(ownEvent)
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: firstTask, modelContext: context)
        viewModel.reset(for: secondTask, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.appliedSnapshotTaskID == secondTask.id)
        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["new task only"])
    }

    @Test("loadEarlierHistory merges the previous page asynchronously")
    func earlierHistoryMergesAsynchronously() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<1_205 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 1_200)
        #expect(viewModel.hasEarlierHistory)

        viewModel.loadEarlierHistory(for: task)
        #expect(viewModel.historyLoadState == .loading)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.snapshot?.sortedEvents.count == 1_205)
        #expect(!viewModel.hasEarlierHistory)
        #expect(viewModel.historyLoadState == .idle)
    }
}
