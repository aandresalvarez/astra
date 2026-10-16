import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Sidebar source observation", .enabled(
    if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15,
    "Modern SwiftData save signals; Sonoma uses the hosted legacy signal integration test"
))
@MainActor
struct SidebarTaskSourceObservationTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func settle(until predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test("Inserts beyond the original snapshot arrive through a save")
    func insertionOutsideSnapshot() async throws {
        let context = try context()
        let seed = AgentTask(title: "Seed", goal: "goal")
        context.insert(seed)
        try context.save()
        let store = SidebarTaskStore(coalesceInterval: 0)
        store.loadIfNeeded(context: context)
        let arrival = AgentTask(title: "Arrival", goal: "goal")
        context.insert(arrival)
        try context.save()
        #expect(await settle { store.tasks.contains { $0.id == arrival.id } })
        #expect(store.fetchCountForTesting == 2)
    }

    @Test("Unsaved changes on any held row update the index without a full fetch")
    func unsavedFieldChanges() async throws {
        let context = try context()
        for title in ["First", "Second"] { context.insert(AgentTask(title: title, goal: "goal")) }
        try context.save()
        let store = SidebarTaskStore(coalesceInterval: 0)
        store.loadIfNeeded(context: context)
        let changed = try #require(store.tasks.last)
        let version = store.tasksVersion
        changed.isPinned = true
        #expect(await settle { store.tasksVersion != version })
        let pinnedVersion = store.tasksVersion
        // A second independent write proves observation was re-armed.
        changed.title = "Renamed without changing updatedAt"
        #expect(await settle { store.tasksVersion != pinnedVersion })
        #expect(store.fetchCountForTesting == 1)
    }

    @Test("A count-preserving saved replacement reaches the snapshot")
    func replacementWithSameCount() async throws {
        let context = try context()
        let old = AgentTask(title: "Old", goal: "goal")
        context.insert(old)
        try context.save()
        let store = SidebarTaskStore(coalesceInterval: 0, membershipProbeInterval: 0)
        store.loadIfNeeded(context: context)
        context.delete(old)
        let replacement = AgentTask(title: "Replacement", goal: "goal")
        context.insert(replacement)
        try context.save()
        #expect(await settle { store.tasks.first?.id == replacement.id })
        #expect(store.tasks.count == 1)
    }

    @Test("Context replacement observes the new store and releases the old observer")
    func contextReplacement() async throws {
        let first = try context()
        let second = try context()
        let store = SidebarTaskStore(coalesceInterval: 0)
        store.loadIfNeeded(context: first)
        store.refreshNow(context: second)
        second.insert(AgentTask(title: "New source", goal: "goal"))
        try second.save()
        #expect(await settle { store.tasks.map(\.title) == ["New source"] })
        first.insert(AgentTask(title: "Old source", goal: "goal"))
        try first.save()
        #expect(store.tasks.map(\.title) == ["New source"])
    }

    @Test("Source observers do not retain a discarded sidebar")
    func observationLifetime() throws {
        let context = try context()
        weak var released: SidebarTaskStore?
        do {
            let store = SidebarTaskStore()
            store.loadIfNeeded(context: context)
            released = store
        }
        #expect(released == nil)
        context.insert(AgentTask(title: "After teardown", goal: "goal"))
        try context.save()
    }

    @Test("An import saved by another context of the container reaches the sidebar")
    func anotherContextInsertion() async throws {
        let context = try context()
        let store = SidebarTaskStore(coalesceInterval: 0)
        store.loadIfNeeded(context: context)
        let importer = ModelContext(context.container)
        importer.insert(AgentTask(title: "Imported", goal: "goal"))
        try importer.save()
        #expect(await settle { store.tasks.map(\.title) == ["Imported"] })
    }

    @Test("A count-preserving replacement from another context bypasses the probe interval")
    func anotherContextReplacement() async throws {
        let context = try context()
        context.insert(AgentTask(title: "Old", goal: "goal"))
        try context.save()
        let store = SidebarTaskStore(coalesceInterval: 0, membershipProbeInterval: 3600)
        store.loadIfNeeded(context: context)
        let importer = ModelContext(context.container)
        let old = try #require(try importer.fetch(FetchDescriptor<AgentTask>()).first)
        importer.delete(old)
        importer.insert(AgentTask(title: "Replacement", goal: "goal"))
        try importer.save()
        #expect(await settle { store.tasks.map(\.title) == ["Replacement"] })
    }

    @Test("Saved field changes from another context refresh held rows")
    func anotherContextFieldChange() async throws {
        let context = try context()
        context.insert(AgentTask(title: "Original", goal: "goal"))
        try context.save()
        let store = SidebarTaskStore(coalesceInterval: 0)
        store.loadIfNeeded(context: context)
        let version = store.tasksVersion
        let writer = ModelContext(context.container)
        let task = try #require(try writer.fetch(FetchDescriptor<AgentTask>()).first)
        task.title = "Renamed"
        task.isPinned = true
        try writer.save()
        #expect(await settle { store.tasksVersion != version })
        #expect(store.tasks.first?.title == "Renamed")
        #expect(store.tasks.first?.isPinned == true)
    }

    @Test("A local edit wins a foreign snapshot without losing pending inserts")
    func externalRefreshPreservesPendingChanges() async throws {
        let context = try context()
        let task = AgentTask(title: "Original", goal: "goal")
        context.insert(task)
        try context.save()
        let store = SidebarTaskStore(coalesceInterval: 0)
        store.loadIfNeeded(context: context)
        task.isPinned = true
        task.title = "Local edit"
        let draft = AgentTask(title: "Unsaved draft", goal: "goal")
        context.insert(draft)
        store.refreshNow(context: context)
        let writer = ModelContext(context.container)
        let foreign = try #require(try writer.fetch(FetchDescriptor<AgentTask>()).first)
        foreign.title = "Renamed"
        try writer.save()
        // A dirty model remains owned by local editing. Its foreign refresh
        // is deferred until that edit is explicitly saved.
        store.refreshNow(context: context)
        #expect(task.isPinned)
        #expect(task.title == "Local edit")
        #expect(store.tasks.contains { $0 === draft })
        #expect(context.hasChanges)
        try context.save()
        #expect(await settle { store.tasks.first { $0.id == task.id }?.title == "Local edit" })
        let durable = try ModelContext(context.container).fetch(FetchDescriptor<AgentTask>())
        #expect(durable.count == 2)
        #expect(durable.first { $0.id == task.id }?.isPinned == true)
        #expect(durable.first { $0.id == task.id }?.title == "Local edit")
    }

    @Test("A failed foreign refetch retries on the next reconciliation")
    func failedForeignRefetchRetries() async throws {
        let context = try context()
        context.insert(AgentTask(title: "Original", goal: "goal"))
        try context.save()
        var attempts = 0
        let store = SidebarTaskStore(coalesceInterval: 0, refetchExternalRows: { context, identifiers in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadUnknown) }
            try SidebarTaskExternalRefresh.fetch(context, identifiers)
        })
        store.loadIfNeeded(context: context)
        let writer = ModelContext(context.container)
        let task = try #require(try writer.fetch(FetchDescriptor<AgentTask>()).first)
        task.title = "Foreign update"
        try writer.save()
        #expect(await settle { attempts == 1 })
        store.refreshNow(context: context)
        #expect(attempts == 2)
        #expect(store.tasks.first?.title == "Foreign update")
        #expect(store.fetchCountForTesting == 1)
    }

    @Test("Saves without task changes do not invalidate the sidebar")
    func unrelatedSavesDoNotSignal() throws {
        let context = try context()
        var signals = 0
        let observation = SidebarTaskChangeObservation(context: context) { _, _ in signals += 1 }
        context.insert(TaskTemplate(name: "Unrelated", mainGoal: "goal"))
        try context.save()
        let writer = ModelContext(context.container)
        writer.insert(TaskSchedule(name: "Unrelated"))
        try writer.save()
        #expect(signals == 0)
        withExtendedLifetime(observation) {}
    }
}
