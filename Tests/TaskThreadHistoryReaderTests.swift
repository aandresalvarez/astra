import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task thread history reader")
@MainActor
struct TaskThreadHistoryReaderTests {
    private func fixture() throws -> (ModelContainer, ModelContext, AgentTask) {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "History", goal: "Inspect history")
        task.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(task)
        return (container, context, task)
    }

    @Test("Initial storage page bounds runs and events before snapshot construction")
    func initialPageIsStorageBounded() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<75 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index * 10))
            context.insert(run)
        }
        for index in 0..<1_300 {
            let event = TaskEvent(task: task, type: "system.info", payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: context)

        #expect(page.runs.count == 50)
        #expect(page.events.count == 1_200)
        #expect(page.totalRunCount == 75)
        #expect(page.totalEventCount == 1_300)
        #expect(page.cursor.hasEarlierRuns)
        #expect(page.cursor.hasEarlierEvents)
    }

    @Test("Event-only history remains completely reachable without omitted runs")
    func eventOnlyHistoryLoadsToCompletion() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<137 {
            let event = TaskEvent(
                task: task,
                eventType: TaskEventTypes.Conversation.userMessage,
                payload: "message \(index)"
            )
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        var page = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 10,
            eventPageSize: 25
        )
        var events = page.events
        while page.cursor.hasEarlierHistory {
            page = try TaskThreadHistoryReader.previousPage(
                taskID: task.id,
                before: page.cursor,
                modelContext: context,
                runPageSize: 10,
                eventPageSize: 25
            )
            events.append(contentsOf: page.events)
        }

        #expect(Set(events.map(\.id)).count == 137)
        #expect(Set(events.map(\.payload)) == Set((0..<137).map { "message \($0)" }))
    }

    @Test("Cursor preserves every row when timestamps tie")
    func timestampTiesDoNotSkipOrDuplicateRows() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let timestamp = Date(timeIntervalSince1970: 100)
        let ids = [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000004",
            "00000000-0000-0000-0000-000000000005"
        ].compactMap(UUID.init(uuidString:))
        for (index, id) in ids.enumerated() {
            let event = TaskEvent(task: task, type: "user.message", payload: "tied \(index)")
            event.id = id
            event.timestamp = timestamp
            context.insert(event)
        }
        try context.save()

        var page = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 2
        )
        var loadedIDs = page.events.map(\.id)
        while page.cursor.hasEarlierEvents {
            page = try TaskThreadHistoryReader.previousPage(
                taskID: task.id,
                before: page.cursor,
                modelContext: context,
                runPageSize: 2,
                eventPageSize: 2
            )
            loadedIDs.append(contentsOf: page.events.map(\.id))
        }

        #expect(loadedIDs.count == ids.count)
        #expect(Set(loadedIDs) == Set(ids))
    }

    @Test("Newer inserts do not shift an existing history cursor")
    func newerInsertDoesNotShiftCursor() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 1...6 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let initial = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 2
        )
        let inserted = TaskEvent(task: task, type: "agent.response", payload: "message 7")
        inserted.timestamp = Date(timeIntervalSince1970: 7)
        context.insert(inserted)
        try context.save()

        let previous = try TaskThreadHistoryReader.previousPage(
            taskID: task.id,
            before: initial.cursor,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 2
        )

        #expect(initial.events.map(\.payload) == ["message 6", "message 5"])
        #expect(previous.events.map(\.payload) == ["message 4", "message 3"])
        #expect(Set(initial.events.map(\.id)).isDisjoint(with: previous.events.map(\.id)))
    }

    @Test("Latest state anchor survives outside the event page")
    func latestStateAnchorIsFetchedSeparately() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let anchor = TaskEvent(task: task, type: "astra.todo.replace", payload: "old plan")
        anchor.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(anchor)
        for index in 0..<50 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "later \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            context.insert(event)
        }
        try context.save()

        let page = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 5,
            eventPageSize: 10
        )

        #expect(!page.events.contains { $0.id == anchor.id })
        #expect(page.stateAnchors.contains { $0.id == anchor.id })
    }

    @Test("State anchors are preserved independently for every loaded run")
    func stateAnchorsAreFetchedPerLoadedRun() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        var anchors: [TaskEvent] = []
        for index in 0..<3 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(run)
            let anchor = TaskEvent(
                task: task,
                type: "astra.permission_manifest",
                payload: "manifest \(index)",
                run: run
            )
            anchor.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            context.insert(anchor)
            anchors.append(anchor)
        }
        for index in 0..<50 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "later \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 100))
            context.insert(event)
        }
        try context.save()

        let latest = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 10
        )
        let previous = try TaskThreadHistoryReader.previousPage(
            taskID: task.id,
            before: latest.cursor,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 10
        )

        #expect(Set(latest.stateAnchors.map(\.id)) == Set(anchors.suffix(2).map(\.id)))
        #expect(previous.stateAnchors.map(\.id) == [anchors[0].id])
    }

    @Test("Batched state anchors match the per-run fetch semantics")
    func batchedStateAnchorsMatchPerRunFetchSemantics() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let types = TaskThreadStateEventPolicy.eventTypes
        var runs: [TaskRun] = []
        var winnersByRun: [UUID: [UUID]] = [:]
        for runIndex in 0..<6 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(runIndex + 1))
            context.insert(run)
            runs.append(run)
            for offset in 0..<3 {
                let type = types[(runIndex + offset) % types.count]
                let superseded = TaskEvent(task: task, type: type, payload: "old", run: run)
                superseded.timestamp = Date(timeIntervalSince1970: Double(runIndex * 10 + offset))
                context.insert(superseded)
                let winner = TaskEvent(task: task, type: type, payload: "new", run: run)
                winner.timestamp = superseded.timestamp.addingTimeInterval(1)
                context.insert(winner)
                winnersByRun[run.id, default: []].append(winner.id)
            }
        }
        var runlessIDs: [UUID] = []
        for offset in 0..<2 {
            let runless = TaskEvent(task: task, type: types[offset], payload: "runless \(offset)")
            runless.timestamp = Date(timeIntervalSince1970: Double(500 + offset))
            context.insert(runless)
            runlessIDs.append(runless.id)
        }
        try context.save()

        let page = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 3,
            eventPageSize: 5
        )

        let expected = Set(runs.suffix(3).flatMap { winnersByRun[$0.id] ?? [] } + runlessIDs)
        #expect(expected.count == 11)
        #expect(Set(page.stateAnchors.map(\.id)) == expected)
    }

    @Test("Off-page runs contribute no state anchors")
    func offPageRunsContributeNoStateAnchors() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        var runs: [TaskRun] = []
        for index in 0..<5 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(run)
            runs.append(run)
            let anchor = TaskEvent(
                task: task,
                type: "astra.todo.replace",
                payload: "plan \(index)",
                run: run
            )
            anchor.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            context.insert(anchor)
        }
        try context.save()

        let page = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 10
        )

        #expect(page.stateAnchors.count == 2)
        #expect(Set(page.stateAnchors.compactMap(\.runID)) == Set(runs.suffix(2).map(\.id)))
    }

    @Test("State anchor ties break on UUID string, not fetch order")
    func stateAnchorTiesBreakOnUUIDString() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        context.insert(run)
        let timestamp = Date(timeIntervalSince1970: 5)
        let ids = [
            "00000000-0000-0000-0000-0000000000AA",
            "00000000-0000-0000-0000-0000000000BB"
        ].compactMap(UUID.init(uuidString:))
        for (index, id) in ids.enumerated() {
            let anchor = TaskEvent(task: task, type: "astra.complete", payload: "tied \(index)", run: run)
            anchor.id = id
            anchor.timestamp = timestamp
            context.insert(anchor)
        }
        try context.save()

        let page = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 5,
            eventPageSize: 10
        )

        #expect(page.stateAnchors.map(\.id) == [ids[1]])
    }

    @Test("Previous page state anchors exclude runless anchors")
    func previousPageStateAnchorsExcludeRunlessAnchors() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let runless = TaskEvent(task: task, type: "astra.complete", payload: "no run")
        runless.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(runless)
        for index in 0..<4 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(run)
            let anchor = TaskEvent(
                task: task,
                type: "astra.permission_manifest",
                payload: "manifest \(index)",
                run: run
            )
            anchor.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            context.insert(anchor)
        }
        try context.save()

        let latest = try TaskThreadHistoryReader.initialPage(
            taskID: task.id,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 10
        )
        let previous = try TaskThreadHistoryReader.previousPage(
            taskID: task.id,
            before: latest.cursor,
            modelContext: context,
            runPageSize: 2,
            eventPageSize: 10
        )

        #expect(latest.stateAnchors.contains { $0.id == runless.id })
        #expect(previous.stateAnchors.count == 2)
        #expect(!previous.stateAnchors.contains { $0.runID == nil })
    }

    @Test("Fifty-run state anchor read stays bounded and fast")
    func fiftyRunStateAnchorReadIsBounded() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let types = TaskThreadStateEventPolicy.eventTypes
        for runIndex in 0..<60 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(runIndex + 1))
            context.insert(run)
            for (typeIndex, type) in types.enumerated() {
                let anchor = TaskEvent(task: task, type: type, payload: "anchor", run: run)
                anchor.timestamp = Date(timeIntervalSince1970: Double(runIndex * 100 + typeIndex))
                context.insert(anchor)
            }
        }
        for index in 0..<1_200 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 10_000))
            context.insert(event)
        }
        try context.save()

        let clock = ContinuousClock()
        let started = clock.now
        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: context)
        let elapsed = started.duration(to: clock.now)

        #expect(page.runs.count == 50)
        #expect(page.stateAnchors.count == 50 * types.count)
        #expect(elapsed < .seconds(2))
    }

    @Test("Tail read returns only events at or after the cursor")
    func tailPageReturnsOnlyEventsAtOrAfterCursor() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<300 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: context)
        let newest = try #require(page.events.first)
        let cursor = TaskThreadEventCursor(timestamp: newest.timestamp, id: newest.id)
        for index in 300..<303 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let tail = try TaskThreadHistoryReader.tailPage(
            taskID: task.id,
            since: cursor,
            modelContext: context
        )

        #expect(tail.events.count == 4)
        #expect(Set(tail.events.map(\.payload)) == Set((299..<303).map { "chunk \($0)" }))
        #expect(!tail.overflowed)
        #expect(tail.totalEventCount == 303)
    }

    @Test("Tail read returns the whole timestamp tie group around its cursor")
    func tailPageIncludesFullTimestampTieGroup() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let timestamp = Date(timeIntervalSince1970: 100)
        let ids = [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000004",
            "00000000-0000-0000-0000-000000000005"
        ].compactMap(UUID.init(uuidString:))
        for (index, id) in ids.enumerated() {
            let event = TaskEvent(task: task, type: "user.message", payload: "tied \(index)")
            event.id = id
            event.timestamp = timestamp
            context.insert(event)
        }
        try context.save()

        let tail = try TaskThreadHistoryReader.tailPage(
            taskID: task.id,
            since: TaskThreadEventCursor(timestamp: timestamp, id: ids[2]),
            modelContext: context
        )

        #expect(Set(tail.events.map(\.id)) == Set(ids))
    }

    @Test("Tail read reports overflow when new events exceed the page size")
    func tailPageOverflowsWhenNewEventsExceedPageSize() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let anchor = TaskEvent(task: task, type: "user.message", payload: "anchor")
        anchor.timestamp = Date(timeIntervalSince1970: 0)
        context.insert(anchor)
        for index in 1...9 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let tail = try TaskThreadHistoryReader.tailPage(
            taskID: task.id,
            since: TaskThreadEventCursor(timestamp: anchor.timestamp, id: anchor.id),
            modelContext: context,
            eventPageSize: 5
        )

        #expect(tail.overflowed)
        #expect(tail.events.count == 5)
    }

    @Test("Tail read totals stay authoritative across inserts and deletes")
    func tailPageReportsAuthoritativeTotals() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        context.insert(run)
        var events: [TaskEvent] = []
        for index in 0..<10 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
            events.append(event)
        }
        try context.save()
        let cursor = TaskThreadEventCursor(timestamp: events[9].timestamp, id: events[9].id)

        let afterInsert = try TaskThreadHistoryReader.tailPage(
            taskID: task.id,
            since: cursor,
            modelContext: context
        )
        #expect(afterInsert.totalEventCount == 10)
        #expect(afterInsert.totalRunCount == 1)

        // A backdated delete never appears in the tail rows, so the total is the
        // only signal the caller has that history changed underneath it.
        context.delete(events[0])
        try context.save()
        let afterDelete = try TaskThreadHistoryReader.tailPage(
            taskID: task.id,
            since: cursor,
            modelContext: context
        )

        #expect(afterDelete.totalEventCount == 9)
        #expect(afterDelete.events.count == afterInsert.events.count)
    }

    @Test("Storage projection caps tool results and drops events for omitted runs")
    func storageProjectionMatchesWindowPolicies() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let loadedRun = TaskRun(task: task)
        let omittedRun = TaskRun(task: task)
        context.insert(loadedRun)
        context.insert(omittedRun)
        var events: [TaskEvent] = []
        for index in 0..<20 {
            events.append(TaskEvent(
                task: task,
                type: "tool.result",
                payload: "result \(index)",
                run: loadedRun
            ))
        }
        let omittedEvent = TaskEvent(
            task: task,
            type: "system.info",
            payload: "belongs to omitted run",
            run: omittedRun
        )
        let runlessEvent = TaskEvent(task: task, type: "user.message", payload: "keep me")
        events.append(omittedEvent)
        events.append(runlessEvent)

        let projected = TaskThreadEventProjectionPolicy.storageEvents(
            events.map(TaskEventSnapshot.init),
            loadedRunIDs: [loadedRun.id]
        )

        #expect(projected.filter { $0.type == "tool.result" }.count == 12)
        #expect(!projected.contains { $0.id == omittedEvent.id })
        #expect(projected.contains { $0.id == runlessEvent.id })
    }

    @Test("Five-thousand-event initial read stays bounded and fast")
    func scaleReadIsBounded() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<5_000 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let clock = ContinuousClock()
        let started = clock.now
        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: context)
        let elapsed = started.duration(to: clock.now)

        #expect(page.events.count == 1_200)
        #expect(page.totalEventCount == 5_000)
        #expect(elapsed < .seconds(2))
    }
}

@Suite("Storage-backed task thread view model")
@MainActor
struct StorageBackedTaskThreadViewModelTests {
    private func fixture() throws -> (ModelContainer, ModelContext, AgentTask) {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Paged history", goal: "Inspect every message")
        task.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(task)
        return (container, context, task)
    }

    @Test("Event-only omission stays visible and loads to completion")
    func eventOnlyHistoryLoadsThroughViewModel() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<1_205 {
            let event = TaskEvent(
                task: task,
                eventType: TaskEventTypes.Conversation.userMessage,
                payload: "message \(index)"
            )
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        let initial = viewModel.snapshot

        #expect(initial?.omittedRunCount == 0)
        #expect(initial?.omittedEventCount == 5)
        #expect(viewModel.hasEarlierHistory)

        viewModel.loadEarlierHistory(for: task)
        await viewModel.waitForPendingWorkForTesting()
        let complete = viewModel.snapshot

        #expect(complete?.sortedEvents.count == 1_205)
        #expect(complete?.omittedRunCount == 0)
        #expect(!viewModel.hasEarlierHistory)
    }

    @Test("New and coalesced stream chunks both publish bounded invalidations")
    func streamChunkMutationsPublishInvalidations() throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        context.insert(run)
        let state = AgentEventRecordingState(maxCoalescedPayloadLength: 1_000)
        var changes: [TaskThreadChange] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .taskThreadDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if let change = notification.object as? TaskThreadChange {
                changes.append(change)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        state.appendConversationChunk(
            eventType: TaskEventTypes.Conversation.agentResponse,
            text: "first ",
            to: task,
            run: run,
            modelContext: context
        )
        state.appendConversationChunk(
            eventType: TaskEventTypes.Conversation.agentResponse,
            text: "second",
            to: task,
            run: run,
            modelContext: context
        )

        #expect(task.events.count == 1)
        #expect(task.events.first?.payload == "first second")
        #expect(changes.map(\.source) == ["event_inserted", "conversation_chunk_coalesced"])
        #expect(changes.allSatisfy { $0.taskID == task.id })
    }

    @Test("Rapid invalidations coalesce before the storage read")
    func rapidInvalidationsCoalesceBeforeRead() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.historyReadCountForTesting == 1)
        #expect(viewModel.appliedSnapshotRevision > 0)

        task.updatedAt = task.updatedAt.addingTimeInterval(1)
        for _ in 0..<20 {
            viewModel.requestSnapshotRefresh(for: task)
        }
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyReadCountForTesting == 2)
    }

    @Test("Pending storage refresh retains its SwiftData container")
    func pendingRefreshRetainsContainer() async throws {
        var container: ModelContainer? = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        weak let retainedContainer = container
        let context = try #require(container?.mainContext)
        let task = AgentTask(title: "Retained history", goal: "Finish the queued read")
        context.insert(task)
        context.insert(TaskEvent(task: task, type: "user.message", payload: "still valid"))
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        task.updatedAt = task.updatedAt.addingTimeInterval(1)
        viewModel.requestSnapshotRefresh(for: task)

        container = nil
        #expect(retainedContainer != nil)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.historyReadCountForTesting == 2)
        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["still valid"])
    }

    @Test("Task switch cancels an earlier history load before it can mutate the new transcript")
    func taskSwitchCancelsStaleHistoryLoad() async throws {
        let (container, context, firstTask) = try fixture()
        defer { _ = container }
        for index in 0..<1_205 {
            let event = TaskEvent(
                task: firstTask,
                type: "user.message",
                payload: "old task \(index)"
            )
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(event)
        }
        let secondTask = AgentTask(title: "New selection", goal: "Stay selected")
        context.insert(secondTask)
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: firstTask, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.omittedEventCount == 5)

        viewModel.loadEarlierHistory(for: firstTask)
        viewModel.reset(for: secondTask, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.appliedSnapshotTaskID == secondTask.id)
        #expect(viewModel.snapshot?.sortedEvents.isEmpty == true)
        #expect(viewModel.historyLoadState == .idle)
    }

    @Test("Streaming appends read the tail instead of the whole page")
    func streamingAppendsUseTailReadsNotFullPages() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<600 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.historyFullReadCountForTesting == 1)
        #expect(viewModel.historyTailReadCountForTesting == 0)

        for index in 600..<605 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
            try context.save()
            viewModel.requestSnapshotRefresh(for: task)
            await viewModel.waitForPendingWorkForTesting()
        }

        #expect(viewModel.historyFullReadCountForTesting == 1)
        #expect(viewModel.historyTailReadCountForTesting == 5)
        #expect(viewModel.historyReadCountForTesting == 6)
        #expect(viewModel.snapshot?.sortedEvents.count == 605)
    }

    @Test("Coalesced stream chunk is re-read by the tail because its timestamp moves forward")
    func coalescedChunkMutationIsPickedUpByTailRead() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        context.insert(run)
        let state = AgentEventRecordingState(maxCoalescedPayloadLength: 1_000)
        state.appendConversationChunk(
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
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "first " } == true)

        state.appendConversationChunk(
            eventType: TaskEventTypes.Conversation.agentResponse,
            text: "second",
            to: task,
            run: run,
            modelContext: context
        )
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(task.events.count == 1)
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "first second" } == true)
        #expect(viewModel.historyTailReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 1)
    }

    @Test("Compaction forces a full re-read instead of stranding deleted rows")
    func compactionForcesFullReread() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 0..<260 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "chunk \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 260)

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        let events = viewModel.snapshot?.sortedEvents ?? []
        #expect(events.contains { $0.type == "activity.compacted" })
        #expect(!events.contains { $0.payload == "chunk 0" })
        #expect(events.contains { $0.payload == "chunk 259" })
        // Compaction announces itself through `TaskThreadHistoryInvalidation`,
        // so the tail read is not merely rejected after the fact — it is never
        // issued. A tail read here can only ever be discarded, because the
        // deletes and the backdated summary all land before the tail cursor.
        #expect(viewModel.historyTailReadCountForTesting == 0)
        #expect(viewModel.historyFullReadCountForTesting == 2)
    }

    @Test("A streaming pre-read save writes no audit line when it succeeds")
    func streamingPreReadSaveDoesNotAuditOnSuccess() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let saved = TaskEvent(task: task, type: "user.message", payload: "saved")
        saved.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(saved)
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()

        // Streaming coalesces into the main context without saving, so the
        // pre-read flush finds `hasChanges` true on essentially every 120 ms
        // invalidation for as long as the task runs.
        let streamed = TaskEvent(task: task, type: "agent.response", payload: "chunk")
        streamed.timestamp = Date(timeIntervalSince1970: 2)
        TaskEventInsertionService.insert(streamed, into: context)
        #expect(context.hasChanges)

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()
        AppLogger.flushForTesting()

        // The save really ran: the read could only see the row through it.
        #expect(viewModel.snapshot?.sortedEvents.count == 2)
        // `AppLogger.emit` is not level-gated, so a `.debug` audit here is
        // per-refresh main-actor work (sanitize, os_log, notification post) plus
        // a line in both the main and the per-task log. Failures stay audited.
        let auditLines = AppLogger.entries
            .filter { $0.taskID == task.id }
            .map(\.message)
            .filter { $0.contains("operation=thread_history_pre_read_save") }
        #expect(auditLines.isEmpty, "Pre-read save audit lines: \(auditLines)")
    }

    @Test("Compaction re-reads the paged-open window instead of collapsing it")
    func compactionPreservesThePagedOpenWindow() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        TaskThreadHistoryInvalidation.resetForTesting()

        // One compactable row among 1_249 preserved `user.message` rows, so the
        // delete and the backdated summary cancel out and the transcript stays
        // wider than a single page after compaction.
        let strandedPayload = "tool call the compaction deletes"
        let stranded = TaskEvent(task: task, type: "tool.call", payload: strandedPayload)
        stranded.timestamp = Date(timeIntervalSince1970: 10)
        context.insert(stranded)
        for index in 1..<1_250 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1) * 10)
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 1_200)
        #expect(viewModel.hasEarlierHistory)

        // The user pages back to the top.
        viewModel.loadEarlierHistory(for: task)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 1_250)
        #expect(!viewModel.hasEarlierHistory)

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()
        #expect(task.events.count == 1_250)

        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        let events = viewModel.snapshot?.sortedEvents ?? []
        // The announced mutation still has to drop the deleted row and surface
        // the backdated summary — the untrusted read replaces rather than
        // merges.
        #expect(!events.contains { $0.payload == strandedPayload })
        #expect(events.contains { $0.type == "activity.compacted" })
        // But replacing must not throw away the pages the user opened: nothing
        // they did triggered this read.
        #expect(events.count == 1_250)
        #expect(!viewModel.hasEarlierHistory)
        #expect(events.contains { $0.payload == "message 1" })
    }

    @Test("Backdated insert forces a full re-read")
    func backdatedInsertForcesFullReread() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        for index in 1...5 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()

        // Mirrors TaskQueue backdating a source message to the run's start.
        let backdated = TaskEvent(task: task, type: "user.message", payload: "backdated")
        backdated.timestamp = Date(timeIntervalSince1970: 2.5)
        context.insert(backdated)
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "backdated" } == true)
        #expect(viewModel.historyTailReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 2)
    }

    @Test("Event deletion forces a full re-read")
    func eventDeletionForcesFullReread() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        var events: [TaskEvent] = []
        for index in 1...5 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
            events.append(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()

        context.delete(events[2])
        task.updatedAt = task.updatedAt.addingTimeInterval(1)
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.snapshot?.sortedEvents.count == 4)
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "message 3" } == false)
        #expect(viewModel.historyTailReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 2)
    }

    @Test("Tail read keeps state anchors that live outside the loaded page")
    func tailReadPreservesStateAnchorsOutsideThePage() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let anchor = TaskEvent(task: task, type: "astra.todo.replace", payload: "old plan")
        anchor.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(anchor)
        for index in 0..<1_205 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.id == anchor.id } == true)

        let appended = TaskEvent(task: task, type: "user.message", payload: "newest")
        appended.timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(appended)
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        // The tail read performs no anchor fetch, so the anchor can only still
        // be here if the merge left the accumulated anchors alone.
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.id == anchor.id } == true)
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "newest" } == true)
        #expect(viewModel.historyTailReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 1)
    }

    @Test("Anchor event arriving in a tail read supersedes the stale anchor")
    func newAnchorEventInTailBecomesAStateAnchor() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        context.insert(run)
        let staleAnchor = TaskEvent(
            task: task,
            type: "astra.permission_manifest",
            payload: "manifest old",
            run: run
        )
        staleAnchor.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(staleAnchor)
        for index in 0..<1_205 {
            let event = TaskEvent(task: task, type: "user.message", payload: "message \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "manifest old" } == true)

        let freshAnchor = TaskEvent(
            task: task,
            type: "astra.permission_manifest",
            payload: "manifest new",
            run: run
        )
        freshAnchor.timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(freshAnchor)
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        let events = viewModel.snapshot?.sortedEvents ?? []
        #expect(events.contains { $0.payload == "manifest new" })
        #expect(!events.contains { $0.payload == "manifest old" })
        #expect(viewModel.historyTailReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 1)
    }

    @Test("Earlier pages survive a tail read")
    func earlierPagesSurviveATailRead() async throws {
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
        viewModel.loadEarlierHistory(for: task)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.count == 1_205)

        let appended = TaskEvent(task: task, type: "user.message", payload: "newest")
        appended.timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(appended)
        try context.save()
        viewModel.requestSnapshotRefresh(for: task)
        await viewModel.waitForPendingWorkForTesting()

        #expect(viewModel.snapshot?.sortedEvents.count == 1_206)
        #expect(viewModel.snapshot?.sortedEvents.contains { $0.payload == "message 0" } == true)
        #expect(!viewModel.hasEarlierHistory)
        #expect(viewModel.historyTailReadCountForTesting == 1)
        #expect(viewModel.historyFullReadCountForTesting == 1)
    }

    @Test("Storage-backed snapshot caps tool results to the chronologically newest, not dictionary order")
    func storageBackedSnapshotKeepsNewestToolResults() async throws {
        let (container, context, task) = try fixture()
        defer { _ = container }
        let run = TaskRun(task: task)
        context.insert(run)
        for index in 0..<20 {
            let event = TaskEvent(task: task, type: "tool.result", payload: "result \(index)", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }
        try context.save()

        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: task, modelContext: context)
        await viewModel.waitForPendingWorkForTesting()
        let snapshot = viewModel.snapshot

        // loadedHistoryEvents is a [UUID: TaskEventSnapshot] dictionary, so the
        // cap must sort chronologically before trimming or it keeps whatever
        // 12 events the dictionary's hash order happens to surface instead of
        // the 12 newest by timestamp.
        let keptPayloads = Set(
            snapshot?.sortedEvents.filter { $0.type == "tool.result" }.map(\.payload) ?? []
        )
        #expect(keptPayloads == Set((8..<20).map { "result \($0)" }))
    }
}
