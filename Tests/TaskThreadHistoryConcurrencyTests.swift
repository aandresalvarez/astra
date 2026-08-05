import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// Regressions from moving the transcript read onto `TaskThreadHistoryStore`
/// and reading only the tail.
///
/// The read now spans an `await`, and the runtime keeps writing into the main
/// context during that suspension. Every test here uses
/// `didCaptureHistoryPageForTesting` to land a write in exactly that window —
/// the offload suite's tests all write, save, and only then refresh, so none of
/// them can reach it.
@Suite("Task thread history concurrency")
@MainActor
struct TaskThreadHistoryConcurrencyTests {
    private func fixture() throws -> (ModelContainer, ModelContext, AgentTask) {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Concurrent history", goal: "Stay consistent under interleaving")
        task.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(task)
        return (container, context, task)
    }

    @Test("A write landing during the read is never cached under the newer revision")
    func writeDuringReadIsNotCachedUnderTheNewerRevision() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        task.status = .running
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

        var didLandDuringRead = false
        viewModel.didCaptureHistoryPageForTesting = {
            guard !didLandDuringRead else { return }
            didLandDuringRead = true
            // The run's final frames land while the read is suspended: the last
            // delta coalesces into the existing row (no new row, no count
            // change) and the completion envelope moves the task terminal.
            recorder.appendConversationChunk(
                eventType: TaskEventTypes.Conversation.agentResponse,
                text: "second",
                to: task,
                run: run,
                modelContext: context
            )
            task.status = .completed
            task.updatedAt = Date()
        }

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()
        #expect(didLandDuringRead)
        viewModel.didCaptureHistoryPageForTesting = nil

        // `updatedAt` no longer moves once a task is terminal, so a page cached
        // under the post-completion key would be served for the rest of the
        // session and on every re-open.
        viewModel.refreshSnapshot(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.lastSnapshotCacheState != "hit")
        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["first second"])
    }

    @Test("A write landing during the read is not dropped by the trigger dedup")
    func writeDuringReadIsNotDroppedByTheTriggerDedup() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        task.status = .running
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

        var didLandDuringRead = false
        viewModel.didCaptureHistoryPageForTesting = {
            guard !didLandDuringRead else { return }
            didLandDuringRead = true
            // Coalescing changes no count field, so the only trigger term that
            // can distinguish the two reads is the revision.
            recorder.appendConversationChunk(
                eventType: TaskEventTypes.Conversation.agentResponse,
                text: "second",
                to: task,
                run: run,
                modelContext: context
            )
        }

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()
        #expect(didLandDuringRead)
        viewModel.didCaptureHistoryPageForTesting = nil

        // The follow-up read is the one that carries the missed delta.
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["first second"])
    }

    @Test("A failed pre-read save surfaces a failure instead of freezing the transcript")
    func failedPreReadSaveSurfacesFailure() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let saved = TaskEvent(task: task, type: "user.message", payload: "saved")
        saved.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(saved)
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 1)
        let readsBeforeFailure = viewModel.historyReadCountForTesting

        // The store reads the persistent file, so a failed save means the read
        // would serve pre-failure rows whose count matches the equally stale
        // `historyTotalEventCount` — the tail invariant accepts them.
        let unsaved = TaskEvent(task: task, type: "user.message", payload: "unsaved")
        unsaved.timestamp = Date(timeIntervalSince1970: 2)
        TaskEventInsertionService.insert(unsaved, into: context)
        viewModel.historyFlushResultOverrideForTesting = { false }

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyReadCountForTesting == readsBeforeFailure)
        if case .failed = viewModel.historyLoadState {
            // Expected: the Retry affordance is visible.
        } else {
            Issue.record("Expected .failed, got \(viewModel.historyLoadState)")
        }

        // And it self-heals once the save can succeed again.
        viewModel.historyFlushResultOverrideForTesting = nil
        viewModel.retryEarlierHistory(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyLoadState == .idle)
        #expect(viewModel.snapshot?.sortedEvents.count == 2)
    }

    @Test("A tail read landing inside an earlier-history load does not disturb it")
    func tailReadInsideEarlierHistoryLoadDoesNotDisturbIt() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        task.status = .running
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

        var didInterleave = false
        var loadStateDuringEarlierPage: TaskThreadHistoryLoadState?
        viewModel.didCaptureHistoryPageForTesting = { [weak viewModel] in
            guard !didInterleave, let viewModel else { return }
            didInterleave = true
            // The earlier page has been read but not merged. A streaming tail
            // read runs to completion inside that window.
            viewModel.refreshSnapshot(for: task)
            await viewModel.waitForHistoryReadForTesting()
            loadStateDuringEarlierPage = viewModel.historyLoadState
        }

        viewModel.loadEarlierHistory(for: task)
        #expect(viewModel.historyLoadState == .loading)
        await viewModel.waitForPendingWorkForTesting()
        viewModel.didCaptureHistoryPageForTesting = nil

        #expect(didInterleave)
        // Reverting to `.idle` mid-load is what reverts the spinner, lets a
        // second click re-read the same page, and consumes the scroll anchor
        // before the earlier events exist.
        #expect(loadStateDuringEarlierPage == .loading)
        // Holding the apply back must not lose the tail read's rows.
        #expect(viewModel.snapshot?.sortedEvents.count == 1_205)
        #expect(!viewModel.hasEarlierHistory)
        #expect(viewModel.historyLoadState == .idle)
    }

    @Test("A failed earlier-history load still renders the rows it deferred")
    func failedEarlierHistoryLoadStillRendersDeferredRows() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        task.status = .running
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

        let streamed = TaskEvent(task: task, type: "user.message", payload: "streamed while paging")
        streamed.timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(streamed)
        try context.save()

        var didInterleave = false
        viewModel.didCaptureHistoryPageForTesting = { [weak viewModel] in
            guard !didInterleave, let viewModel else { return }
            didInterleave = true
            // The user taps "Load earlier messages" while this streaming read is
            // suspended, so its apply is deferred to the earlier load. That load
            // then fails before it can read its page.
            viewModel.historyFlushResultOverrideForTesting = { false }
            viewModel.loadEarlierHistory(for: task)
        }

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()
        viewModel.didCaptureHistoryPageForTesting = nil
        viewModel.historyFlushResultOverrideForTesting = nil

        #expect(didInterleave)
        // The earlier page is what failed, so its banner has to stay up...
        if case .failed = viewModel.historyLoadState {
            // Expected: the Retry affordance is visible.
        } else {
            Issue.record("Expected .failed, got \(viewModel.historyLoadState)")
        }
        // ...but the streamed row merged before the failure, and dropping its
        // apply is the same silent stall as a frozen transcript.
        #expect(viewModel.snapshot?.sortedEvents.count == 1_201)
        #expect(viewModel.snapshot?.sortedEvents.last?.payload == "streamed while paging")

        // Retry still re-issues the earlier page rather than the latest one.
        viewModel.retryEarlierHistory(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyLoadState == .idle)
        #expect(viewModel.snapshot?.sortedEvents.count == 1_206)
        #expect(!viewModel.hasEarlierHistory)
    }

    @Test("A one-row compaction does not strand the deleted event in the transcript")
    func oneRowCompactionDoesNotStrandTheDeletedEvent() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        TaskThreadHistoryInvalidation.resetForTesting()

        // 201 events whose oldest 151 hold exactly one compactable row, so the
        // delete and the backdated summary cancel out in the authoritative
        // count and no count-based invariant can observe the change.
        let strandedPayload = "tool call the compaction deletes"
        let stranded = TaskEvent(task: task, type: "tool.call", payload: strandedPayload)
        stranded.timestamp = Date(timeIntervalSince1970: 10)
        context.insert(stranded)
        for index in 1..<201 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1) * 10)
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 201)

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()
        // The blind spot: one delete, one backdated insert, net zero.
        #expect(task.events.count == 201)
        #expect(task.events.contains { $0.type == "activity.compacted" })

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        let events = viewModel.snapshot?.sortedEvents ?? []
        #expect(!events.contains { $0.payload == strandedPayload })
        #expect(events.contains { $0.type == "activity.compacted" })
    }
}
