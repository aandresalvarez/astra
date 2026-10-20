import Foundation
import Observation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Usage dashboard snapshots")
@MainActor
struct UsageDashboardStoreTests {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun

        init() throws {
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            context = ModelContext(container)
            context.autosaveEnabled = false
            task = AgentTask(title: "Usage", goal: "Synthetic")
            task.status = .completed
            task.tokensUsed = 100
            task.costUSD = 1.5
            run = TaskRun(task: task)
            run.status = .completed
            context.insert(task)
            context.insert(run)
            try context.save()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test("Reader aggregates committed values and filters tasks and runs independently")
    func readerCountsAndFilters() async throws {
        let fixture = try Fixture()
        let now = Date()
        fixture.task.createdAt = now.addingTimeInterval(-10 * 86400)
        fixture.run.startedAt = now
        let failure = AgentTask(title: "Failed", goal: "Synthetic")
        failure.status = .budgetExceeded
        failure.tokensUsed = 50
        failure.costUSD = 0.5
        fixture.context.insert(failure)
        try fixture.context.save()
        let reader = UsageDashboardReader(container: fixture.container)
        let all = try await reader.read(timeFilter: .allTime)
        #expect(all.tasks.count == 2)
        #expect(all.tasks.first?.id == failure.id)
        #expect(all.totalTokens == 150)
        #expect(all.totalCost == 2)
        #expect(all.completedCount == 1)
        #expect(all.failedCount == 1)
        #expect(all.totalRuns == 1)
        for filter in [TimeFilter.today, .last7Days] {
            let recent = try await reader.read(timeFilter: filter)
            #expect(recent.tasks.map(\.id) == [failure.id])
            #expect(recent.totalTokens == 50)
            #expect(recent.totalRuns == 1)
        }
    }

    @Test("A value-only save refreshes every open window without a count change")
    func valueOnlySaveRefreshesWindows() async throws {
        let fixture = try Fixture()
        let first = UsageDashboardStore()
        let second = UsageDashboardStore()
        defer { first.stop(); second.stop() }
        first.start(container: fixture.container, timeFilter: .allTime)
        second.start(container: fixture.container, timeFilter: .allTime)
        try await waitUntil { first.summary?.totalTokens == 100 && second.summary?.totalTokens == 100 }
        fixture.task.tokensUsed = 350
        fixture.task.status = .failed
        try fixture.context.save()
        try await waitUntil { first.summary?.totalTokens == 350 && second.summary?.failedCount == 1 }
        #expect(first.summary?.failedCount == 1)
        #expect(second.summary?.totalTokens == 350)
    }

    @Test("Stream output saves refresh the source without invalidating the render graph")
    func outputOnlySaveDoesNotRepublish() async throws {
        let fixture = try Fixture()
        let reads = ReadCounter()
        let store = UsageDashboardStore { container, filter in
            await reads.increment()
            return try await UsageDashboardReader(container: container).read(timeFilter: filter)
        }
        defer { store.stop() }
        store.start(container: fixture.container, timeFilter: .allTime)
        try await waitUntil { store.summary != nil && !store.isRefreshing }
        let changed = AgentLockedBuffer()
        withObservationTracking {
            _ = store.summary
            _ = store.errorMessage
        } onChange: {
            changed.append("changed")
        }
        fixture.run.appendOutput("A streamed token that changes no usage metadata")
        try fixture.context.save()
        let deadline = ContinuousClock.now + .seconds(5)
        while await reads.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await reads.count >= 2, "Exercise a real save-driven refresh")
        try await waitUntil { !store.isRefreshing }
        #expect(changed.value.isEmpty)
    }

    @Test("External saves and count-preserving replacement cannot leave stale rows")
    func externalSaveAndReplacement() async throws {
        let fixture = try Fixture()
        let store = UsageDashboardStore()
        defer { store.stop() }
        store.start(container: fixture.container, timeFilter: .allTime)
        try await waitUntil { store.summary?.tasks.count == 1 }
        let external = ModelContext(fixture.container)
        external.autosaveEnabled = false
        let old = try #require(external.fetch(FetchDescriptor<AgentTask>()).first)
        external.delete(old)
        let replacement = AgentTask(title: "Replacement", goal: "Synthetic")
        external.insert(replacement)
        try external.save()
        try await waitUntil { store.summary?.tasks.first?.id == replacement.id }
        #expect(store.summary?.tasks.count == 1)
        #expect(store.summary?.totalRuns == 0)
    }

    @Test("Filtering during an in-flight read discards the old filter's result")
    func staleFilterCannotApply() async throws {
        let fixture = try Fixture()
        fixture.task.createdAt = Date(timeIntervalSince1970: 0)
        try fixture.context.save()
        let gate = ReadGate()
        let store = UsageDashboardStore { container, filter in
            if filter == .allTime { await gate.wait() }
            return try await UsageDashboardReader(container: container).read(timeFilter: filter)
        }
        defer { store.stop(); Task { await gate.open() } }
        store.start(container: fixture.container, timeFilter: .allTime)
        await gate.waitForEntry()
        store.start(container: fixture.container, timeFilter: .today)
        await gate.open()
        try await waitUntil { store.summary != nil && !store.isRefreshing }
        #expect(store.summary?.tasks.isEmpty == true)
    }

    @Test("Closing a window discards an in-flight read and releases its subscription")
    func closingDiscardsInFlightRead() async throws {
        let fixture = try Fixture()
        let gate = ReadGate()
        let store = UsageDashboardStore { container, filter in
            await gate.wait()
            return try await UsageDashboardReader(container: container).read(timeFilter: filter)
        }
        store.start(container: fixture.container, timeFilter: .allTime)
        await gate.waitForEntry()
        store.stop()
        await gate.open()
        fixture.task.tokensUsed = 500
        try fixture.context.save()
        await Task.yield()
        #expect(store.summary == nil)
        #expect(!store.isRefreshing)
    }

    @Test("Read errors remain visible and retry can recover")
    func errorAndRetry() async throws {
        let fixture = try Fixture()
        let attempt = ReadAttempt()
        let store = UsageDashboardStore { container, filter in
            try await attempt.check()
            return try await UsageDashboardReader(container: container).read(timeFilter: filter)
        }
        defer { store.stop() }
        store.start(container: fixture.container, timeFilter: .allTime)
        try await waitUntil { store.errorMessage != nil && !store.isRefreshing }
        #expect(store.summary == nil)
        store.refresh()
        try await waitUntil { store.summary != nil && !store.isRefreshing }
        #expect(store.errorMessage == nil)
        #expect(store.summary?.totalTokens == 100)
    }
}

private actor ReadGate {
    var isOpen = false
    var entered = false
    var entryWaiters: [CheckedContinuation<Void, Never>] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let pendingEntries = entryWaiters
        entryWaiters = []
        pendingEntries.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor ReadAttempt {
    enum Failure: Error { case read }
    var didFail = false
    func check() throws {
        if !didFail { didFail = true; throw Failure.read }
    }
}

private actor ReadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
