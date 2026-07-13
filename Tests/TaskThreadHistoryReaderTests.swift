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

    private func awaitSnapshot(
        _ viewModel: TaskThreadViewModel,
        timeout: TimeInterval = 5,
        where predicate: (TaskThreadSnapshot) -> Bool
    ) async -> TaskThreadSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = viewModel.snapshot, predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return viewModel.snapshot
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
        let initial = await awaitSnapshot(viewModel) { $0.omittedEventCount == 5 }

        #expect(initial?.omittedRunCount == 0)
        #expect(initial?.omittedEventCount == 5)
        #expect(viewModel.hasEarlierHistory)

        viewModel.loadEarlierHistory(for: task)
        let complete = await awaitSnapshot(viewModel) { $0.omittedEventCount == 0 }

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
        _ = await awaitSnapshot(viewModel) { _ in
            viewModel.historyReadCountForTesting == 1 && viewModel.appliedSnapshotRevision > 0
        }

        task.updatedAt = task.updatedAt.addingTimeInterval(1)
        for _ in 0..<20 {
            viewModel.requestSnapshotRefresh(for: task)
        }
        let deadline = Date().addingTimeInterval(2)
        while viewModel.historyReadCountForTesting < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(viewModel.historyReadCountForTesting == 2)
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
        _ = await awaitSnapshot(viewModel) { $0.omittedEventCount == 5 }

        viewModel.loadEarlierHistory(for: firstTask)
        viewModel.reset(for: secondTask, modelContext: context)
        _ = await awaitSnapshot(viewModel) { _ in
            viewModel.appliedSnapshotTaskID == secondTask.id
        }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.appliedSnapshotTaskID == secondTask.id)
        #expect(viewModel.snapshot?.sortedEvents.isEmpty == true)
        #expect(viewModel.historyLoadState == .idle)
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
        let snapshot = await awaitSnapshot(viewModel) {
            $0.sortedEvents.filter { $0.type == "tool.result" }.count == 12
        }

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
