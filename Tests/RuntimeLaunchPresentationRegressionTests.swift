import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Provider launch presentation regressions", .serialized)
@MainActor
struct RuntimeLaunchPresentationRegressionTests {
    @Test("A retained provider reservation is an unlaunched outcome, including after an earlier completed run")
    func retainedReservationNeverOffersResultApproval() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let previous = TaskRun(task: task); previous.status = .completed; h.context.insert(previous)
        let oldReceipt = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"finished\",\"providerLaunchCount\":1,\"providerProcess\":{\"startedSeconds\":100}}", run: previous)
        let run = TaskRun(task: task); h.context.insert(run)
        run.status = .failed; run.stopReason = RuntimeProviderResourceRegistry.Block.stopReason
        let receipt = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"notStarted\",\"providerLaunchCount\":0}", run: run)
        let detail = try #require(RuntimeLaunchPresentation.terminalDetail(run: .init(input: .init(run: run)),
            events: [oldReceipt, receipt].map(TaskEventSnapshot.init(event:))))
        #expect(detail.id == "runtime-unlaunched-terminal")
        #expect(detail.title == "Provider did not start")
        #expect(detail.summary.contains("remains protected"))
        #expect(!detail.summary.contains("exceeded"))
    }

    @Test("A provider preparation timeout must not charge unexecuted prompt tokens")
    func timeoutDoesNotSpend() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        task.tokensUsed = 70
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        AgentRuntimeWorker.recordEstimatedUsageIfProviderDidNotReport(
            runtimeAdapter: AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI),
            selectedRuntime: .antigravityCLI, prompt: String(repeating: "Unexecuted prompt. ", count: 100),
            task: task, run: run, modelContext: h.context,
            providerStarted: owner.record.hasProviderLaunch)
        owner.reconcileUsage()
        #expect(run.tokensUsed == 0)
        #expect(task.tokensUsed == 70)
        let saved = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(saved.limits.tokensSpent == 0)
    }

    @Test("Successful acquisition must stop claiming another execution holds the resource")
    func acquisitionClearsWaiting() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: h.rootURL.path)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("locks"), registeredStoreRoots: [])
        try owner.waitingForProviderState(key)
        let lease = try await gate.acquire(key, owner: owner, timeoutSeconds: 5)
        let state = RuntimeLaunchPresentation.preparation(for: .init(input: .init(run: run)),
            events: task.events.map(TaskEventSnapshot.init(event:)))
        #expect(state?.state == .preparing)
        _ = owner.releaseProviderSharedState()
        await gate.release(lease)
    }

    @Test("Two launches must not count the first execution as preparation")
    func multipleLaunchDuration() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .cursorCLI, goal: "Synthetic", model: "test")
        let run = TaskRun(task: task); h.context.insert(run)
        run.startedAt = Date(timeIntervalSince1970: 9910)
        run.completedAt = Date(timeIntervalSince1970: 10000); run.status = .completed
        var events: [TaskEventSnapshot] = []
        for start in [9940, 9980] {
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: "{\"state\":\"working\",\"providerProcess\":{\"startedSeconds\":\(start)}}", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(start)); h.context.insert(event)
            events.append(.init(event: event))
        }
        let label = RuntimeLaunchPresentation.durationLabel(run: .init(input: .init(run: run)),
            events: events, now: run.completedAt!, format: { "\($0)s" })
        #expect(label == "Elapsed 90s")
    }

    @Test("Reopening a paginated transcript retains the launch receipt", arguments: [false, true])
    func paginatedReceipt(waiting: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let run = TaskRun(task: task); h.context.insert(run)
        run.startedAt = Date(timeIntervalSince1970: 9910)
        let payload = waiting
            ? "{\"state\":\"preparing\",\"preparationStage\":\"waiting_for_provider\"}"
            : "{\"state\":\"working\",\"providerProcess\":{\"startedSeconds\":9940}}"
        let receipt = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: payload, run: run)
        receipt.timestamp = Date(timeIntervalSince1970: 9940); h.context.insert(receipt)
        for index in 0..<30 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "later event \(index)", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(9950 + index)); h.context.insert(event)
        }
        try h.context.save()
        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, ownerID: task.persistentModelID,
            modelContext: ModelContext(h.container), eventPageSize: 10)
        let events = page.events + page.stateAnchors
        let snapshot = TaskRunSnapshot(input: try #require(page.runs.first))
        #expect(RuntimeLaunchPresentation.receipt(for: snapshot, events: events) != nil)
        let label = RuntimeLaunchPresentation.durationLabel(run: snapshot, events: events,
            now: Date(timeIntervalSince1970: 10000), format: { "\($0)s" })
        #expect(label == (waiting ? "Waiting for provider configuration · 90s" : "Running for 60s · preparation 30s"))
    }

    @Test("Launch anchors refresh incrementally and remain isolated between imported copies")
    func historyRefreshAndOwnerIsolation() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let original = h.makeTask(runtime: .cursorCLI, goal: "Original", model: "test")
        let copy = h.makeTask(runtime: .antigravityCLI, goal: "Copy", model: "test")
        copy.id = original.id
        let runID = UUID()
        var runs: [TaskRun] = []
        for (index, task) in [original, copy].enumerated() {
            task.status = .running
            let run = TaskRun(task: task); run.id = runID; h.context.insert(run); runs.append(run)
            let payload = index == 0
                ? "{\"state\":\"working\",\"providerLaunchCount\":1,\"providerProcess\":{\"startedSeconds\":100}}"
                : "{\"state\":\"preparing\",\"providerLaunchCount\":0,\"preparationStage\":\"waiting_for_provider\"}"
            let anchor = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: payload, run: run)
            anchor.timestamp = Date(timeIntervalSince1970: 100); h.context.insert(anchor)
            for offset in 0..<(TaskThreadHistoryReader.defaultEventPageSize + 5) {
                let event = TaskEvent(task: task, type: "agent.response", payload: "history \(offset)", run: run)
                event.timestamp = Date(timeIntervalSince1970: Double(200 + offset)); h.context.insert(event)
            }
        }
        try h.context.save()
        let model = TaskThreadViewModel()
        model.reset(for: original, modelContext: h.context); await model.waitForPendingWorkForTesting()
        func receipt() throws -> RuntimeLaunchPresentation.Receipt {
            let snapshot = try #require(model.snapshot)
            let run = try #require(snapshot.latestRun)
            return try #require(RuntimeLaunchPresentation.receipt(for: run, events: snapshot.sortedEvents))
        }
        #expect(try receipt().providerLaunchCount == 1)
        let fallback = TaskEvent(task: original, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"working\",\"providerLaunchCount\":2,\"providerProcess\":{\"startedSeconds\":200}}", run: runs[0])
        h.context.insert(fallback); try h.context.save()
        model.requestSnapshotRefresh(for: original); await model.waitForPendingWorkForTesting()
        #expect(try receipt().providerLaunchCount == 2)
        #expect(model.historyTailReadCountForTesting == 1)
        model.reset(for: copy, modelContext: h.context); await model.waitForPendingWorkForTesting()
        #expect(try receipt().providerLaunchCount == 0)
        #expect(try receipt().preparationStage == "waiting_for_provider")
        model.reset(for: original, modelContext: h.context); await model.waitForPendingWorkForTesting()
        #expect(try receipt().providerLaunchCount == 2)
    }

    @Test("A cancelled fallback cannot erase the fact that its first provider ran")
    func cancelledFallbackWasNotUnlaunched() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .cursorCLI, goal: "Synthetic", model: "test")
        let run = TaskRun(task: task); h.context.insert(run)
        run.status = .cancelled; run.completedAt = Date()
        let anchor = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"notStarted\",\"providerLaunchCount\":1}", run: run)
        let snapshot = TaskRunSnapshot(input: .init(run: run)), events = [TaskEventSnapshot(event: anchor)]
        #expect(RuntimeLaunchPresentation.terminalDetail(run: snapshot, events: events) == nil)
        #expect(RuntimeLaunchPresentation.durationLabel(run: snapshot, events: events, now: Date(), format: { "\($0)s" })?.contains("before provider start") == false)
    }
}
