import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Imported task history isolation")
@MainActor
struct ImportedTaskHistoryIsolationTests {
    private func fixture() throws -> (ModelContainer, AgentTask, AgentTask) {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self, TaskTurnRequest.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let id = UUID(), timestamp = Date(timeIntervalSince1970: 100)
        let original = AgentTask(title: "Original", goal: "Original")
        let copy = AgentTask(title: "Imported", goal: "Imported")
        for task in [original, copy] {
            task.id = id
            task.status = .completed
            task.createdAt = timestamp
            task.updatedAt = timestamp
            task.completedAt = timestamp
            context.insert(task)
            context.insert(TaskEvent(task: task, type: "user.message", payload: task.title))
        }
        for task in [original, copy] { task.updatedAt = timestamp }
        try context.save()
        return (container, original, copy)
    }

    @Test("Legacy ownership reads provenance without materializing a large tool history")
    func legacyOwnershipLeavesToolHistoryCold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self, TaskTurnRequest.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("store")))
        let writer = ModelContext(container)
        writer.autosaveEnabled = false
        let task = AgentTask(title: "Legacy", goal: "Legacy")
        writer.insert(task)
        let events = (0..<1000).map { offset in
            let event = TaskEvent(task: task, type: "tool.result", payload: "Tool \(offset)")
            writer.insert(event)
            return event
        }
        for sequence in 1...20 {
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: sequence)
            request.executionPolicySnapshotJSON = nil
            writer.insert(request)
        }
        try writer.save()
        let eventOwners = events.map(\.persistentModelID)
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let coldTask = try #require(reader.fetch(FetchDescriptor<AgentTask>()).first)
        let requests = try reader.fetch(FetchDescriptor<TaskTurnRequest>())
        var resolver = TaskTurnRequestOwnership.Resolver(candidates: [coldTask])
        for request in requests { #expect(resolver.resolve(request)?.persistentModelID == task.persistentModelID) }
        #expect(eventOwners.allSatisfy { owner in
            let event: TaskEvent? = reader.registeredModel(for: owner)
            return event == nil
        })
        // A fresh operation sees an unsaved import marker; it is never a durable cache.
        reader.insert(TaskEvent(task: coldTask, eventType: TaskEventTypes.Task.historyImported, payload: "Imported"))
        var afterImport = TaskTurnRequestOwnership.Resolver(candidates: [coldTask])
        for request in requests { #expect(afterImport.resolve(request) == nil) }
    }

    @Test("Terminal snapshots with identical portable metadata have different owners")
    func terminalCacheSeparatesImportedCopies() throws {
        let (container, original, copy) = try fixture()
        defer { _ = container }
        #expect(TaskThreadSnapshotCacheKey(task: original, maxRuns: 50)
            != TaskThreadSnapshotCacheKey(task: copy, maxRuns: 50))
        #expect(TaskCanvasRefreshSignature(task: original) != TaskCanvasRefreshSignature(task: copy))
        #expect(WorkspaceCanvasItemSelectionTransition.itemAfterTaskSelectionChange(currentItem: .plan,
            previousTaskID: original.id, nextTaskID: copy.id, isComposingTask: false, ownerChanged: true) == nil)
    }

    @Test("Opening either imported copy reads only its own conversation")
    func transcriptSeparatesImportedCopies() async throws {
        let (container, original, copy) = try fixture()
        let viewModel = TaskThreadViewModel()
        viewModel.reset(for: original, modelContext: container.mainContext)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["Original"])
        viewModel.reset(for: copy, modelContext: container.mainContext)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.snapshot?.sortedEvents.map(\.payload) == ["Imported"])
    }

    @Test("Pagination counts and boundaries are applied within the selected owner")
    func pagesNeverSpendTheirLimitOnAnotherCopy() throws {
        let (container, original, copy) = try fixture()
        let context = container.mainContext
        for offset in 0..<8 {
            let eventID = UUID()
            for task in [original, copy] {
                let event = TaskEvent(task: task, type: "user.message", payload: "\(task.title)-\(offset)")
                event.id = eventID
                event.timestamp = Date(timeIntervalSince1970: Double(200 + offset))
                context.insert(event)
            }
        }
        try context.save()
        #expect(throws: (any Error).self) {
            try TaskThreadHistoryReader.initialPage(taskID: original.id, modelContext: context)
        }
        for task in [original, copy] {
            var page = try TaskThreadHistoryReader.initialPage(taskID: task.id, ownerID: task.persistentModelID,
                modelContext: context, eventPageSize: 2)
            #expect(page.totalEventCount == 9)
            var payloads = page.events.map(\.payload)
            while page.cursor.hasEarlierHistory {
                page = try TaskThreadHistoryReader.previousPage(taskID: task.id, ownerID: task.persistentModelID,
                    before: page.cursor, modelContext: context, eventPageSize: 2)
                payloads += page.events.map(\.payload)
            }
            #expect(payloads.count == 9)
            #expect(payloads.allSatisfy { $0.hasPrefix(task.title) })
        }
    }

    @Test("Summary compaction cannot read or overwrite an imported copy")
    func compactionOwnsOnlyItsRows() throws {
        let (container, original, copy) = try fixture()
        let context = container.mainContext
        let foreign = TaskEvent(task: copy, type: TaskEventTypes.Activity.compacted.rawValue,
            payload: "History summary (original details retained). FOREIGN")
        context.insert(foreign)
        for offset in 0..<230 {
            for task in [original, copy] {
                let event = TaskEvent(task: task, type: "user.message", payload: "Always prefer \(task.title)-\(offset)")
                event.timestamp = Date(timeIntervalSince1970: Double(offset))
                context.insert(event)
            }
        }
        try context.save()
        AgentEventCompactor.compactEvents(for: original, modelContext: context)
        #expect(foreign.payload == "History summary (original details retained). FOREIGN")
        let summary = try #require(original.events.first { $0.type == TaskEventTypes.Activity.compacted.rawValue })
        #expect(!summary.payload.contains("Imported"))
        #expect(summary.payload.contains("181 older events"))
    }

    @Test("Requests, pending instructions, sequence and sidebar state belong to one copy")
    func requestsHavePersistentOwners() throws {
        let (container, original, copy) = try fixture()
        let context = container.mainContext
        let sourceID = try #require(original.events.first?.id)
        copy.events.first?.id = sourceID
        let requestA = TaskTurnRequest(task: original, messageEventID: sourceID, sequence: 1, state: .completed)
        let requestB = TaskTurnRequest(task: copy, messageEventID: sourceID, sequence: 99, state: .waitingForWorker)
        context.insert(requestA); context.insert(requestB); try context.save()
        #expect(try TaskTurnRequestRepository.requests(for: original, in: context).map(\.id) == [requestA.id])
        #expect(try TaskTurnRequestRepository.nextSequence(for: original, in: context) == 2)
        #expect(try TaskTurnRequestRepository.nextSequence(for: copy, in: context) == 100)
        #expect(TaskPendingTurnMessageVisibility.pendingMessageEventIDs(for: original).isEmpty)
        #expect(TaskPendingTurnMessageVisibility.pendingMessageEventIDs(for: copy) == [sourceID])
        let activities = TaskActivityPresentation.resolveByOwner(tasks: [original, copy], requests: [requestA, requestB])
        #expect(activities[original.persistentModelID] == nil)
        #expect(activities[copy.persistentModelID]?.kind == .waitingForWorker)
        let background = ModelContext(container)
        #expect(try TaskTurnRequestOwnership.resolve(requestB, in: background)?.persistentModelID == copy.persistentModelID)
    }

    @Test("Deleting a candidate cannot grant an ambiguous legacy request to the survivor")
    func deletingCopyDoesNotAdoptLegacyRequest() throws {
        let (container, original, copy) = try fixture()
        let context = container.mainContext
        let request = TaskTurnRequest(task: original, messageEventID: UUID(), sequence: 1)
        request.executionPolicySnapshotJSON = nil
        context.insert(request); try context.save()
        #expect(try TaskTurnRequestOwnership.resolve(request, in: context) == nil)
        try TaskTurnRequestOwnership.preserveLegacyBindings(taskID: original.id, in: context)
        context.delete(original); try context.save()
        #expect(try TaskTurnRequestOwnership.resolve(request, in: context) == nil)
        #expect(TaskTurnOwnerBinding(json: request.executionPolicySnapshotJSON) == .invalid)
        #expect(!copy.isDeleted)
    }

    @Test("Wrong-owner runtime callbacks cannot complete or admit another copy's request")
    func foreignRuntimeCallbacksAreRejected() throws {
        let (container, original, copy) = try fixture()
        let context = container.mainContext
        let request = TaskTurnRequest(task: original, messageEventID: UUID(), sequence: 1, state: .admitted)
        let run = TaskRun(task: copy)
        context.insert(request); context.insert(run); try context.save()
        let begin = PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: run, task: copy, in: context)
        #expect(!begin.persisted && begin.request == nil)
        #expect(request.state == .admitted)
        run.status = .completed
        PersistedTurnRuntimeEventLinker.finishRuntime(request: request, run: run, task: copy, in: context)
        #expect(request.state == .admitted)
    }

    @Test("Scheduled results resolve the source within the schedule's local workspace")
    func scheduledResultCannotWriteAnotherCopy() throws {
        let (container, original, copy) = try fixture()
        let context = container.mainContext
        let a = Workspace(name: "A", primaryPath: "/tmp/history-a"), b = Workspace(name: "B", primaryPath: "/tmp/history-b")
        context.insert(a); context.insert(b)
        original.workspace = a; copy.workspace = b
        let scheduled = AgentTask(title: "Scheduled", goal: "Result", workspace: b)
        scheduled.status = .completed
        let run = TaskRun(task: scheduled)
        run.status = .completed; run.tokensUsed = 123; run.setOutput("B RESULT")
        let schedule = TaskSchedule(name: "Routine", goal: "Result", workspace: b)
        schedule.resultMode = .sameThread; schedule.sourceTaskID = copy.id
        context.insert(scheduled); context.insert(run); context.insert(schedule)
        try context.save()
        TaskQueue().routeScheduleResult(task: scheduled, scheduleID: schedule.id, modelContext: context)
        #expect(original.runs.isEmpty && original.tokensUsed == 0)
        #expect(copy.runs.count == 1 && copy.tokensUsed == 123)
        #expect(copy.runs.first?.output == "B RESULT")
    }

    private final class PageGate {
        private var parked: CheckedContinuation<Void, Never>?
        private var arrived: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                parked = continuation
                arrived?.resume(); arrived = nil
            }
        }
        func waitUntilPaused() async {
            if parked != nil { return }
            await withCheckedContinuation { arrived = $0 }
        }
        func release() { let continuation = parked; parked = nil; continuation?.resume() }
    }

    @Test("A cancelled earlier-page load cannot finish a newer load after A to B to A")
    func suspendedPageCannotClobberNewOwnerGeneration() async throws {
        let (container, a, b) = try fixture()
        let context = container.mainContext
        a.status = .running; b.status = .running
        let seededCount = TaskThreadHistoryPagePolicy.eventCount + 4
        for offset in 0..<seededCount {
            let event = TaskEvent(task: a, type: "user.message", payload: "A \(offset)")
            event.timestamp = Date(timeIntervalSince1970: Double(offset))
            context.insert(event)
        }
        try context.save()
        let vm = TaskThreadViewModel(), oldGate = PageGate(), newGate = PageGate()
        defer { oldGate.release(); newGate.release(); vm.didCaptureHistoryPageForTesting = nil }
        vm.reset(for: a, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        vm.didCaptureHistoryPageForTesting = { await oldGate.pause() }
        vm.loadEarlierHistory(for: a)
        await oldGate.waitUntilPaused()
        let oldLoad = try #require(vm.earlierHistoryTaskForTesting)
        vm.didCaptureHistoryPageForTesting = nil
        vm.reset(for: b, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        vm.reset(for: a, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        vm.didCaptureHistoryPageForTesting = {
            vm.didCaptureHistoryPageForTesting = nil
            await newGate.pause()
        }
        vm.loadEarlierHistory(for: a)
        await newGate.waitUntilPaused()
        let newLoad = try #require(vm.earlierHistoryTaskForTesting)
        context.insert(TaskEvent(task: a, type: "user.message", payload: "A new tail"))
        try context.save()
        vm.refreshSnapshot(for: a)
        await vm.waitForHistoryReadForTesting()
        oldGate.release()
        await oldLoad.value
        #expect(vm.historyLoadState == .loading)
        newGate.release()
        await newLoad.value
        await vm.waitForPendingWorkForTesting()
        #expect(vm.historyLoadState == .idle)
        #expect(vm.snapshot?.sortedEvents.count == seededCount + 2)
        #expect(!vm.hasEarlierHistory)
        #expect(vm.snapshot?.sortedEvents.contains { $0.payload == "Imported" } == false)
        #expect(vm.snapshot?.sortedEvents.contains { $0.payload == "A new tail" } == true)
    }
}
