import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Running task count")
@MainActor
struct RunningTaskCountPredicateTests {
    private func seed(_ context: ModelContext) throws {
        let workspace = Workspace(name: "Count", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        for (index, status) in [TaskStatus.running, .running, .pendingUser, .completed, .draft].enumerated() {
            let task = AgentTask(title: "t\(index)", goal: "g", workspace: workspace)
            task.status = status
            context.insert(task)
        }
        try context.save()
    }

    private func onDiskContainer() throws -> (ModelContainer, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-running-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("default.store"))
        )
        return (container, root)
    }

    @Test("Completing a running task updates the count on disk and after reopening")
    func completionUpdatesRunningCountOnDisk() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try seed(context)
        let task = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.status == .running })
        task.status = .completed
        task.completedAt = Date()
        try context.save()
        #expect(AppUpdateSafety.runningTaskCount(in: context) == 1)
        #expect(AppUpdateSafety.runningTaskCount(in: ModelContext(container)) == 1)
    }

    @Test("Counts only .running tasks on a real on-disk store")
    func countsRunningTasksOnDisk() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(container.mainContext)
        #expect(AppUpdateSafety.runningTaskCount(in: container.mainContext) == 2)
    }

    @Test("Counts only .running tasks on an in-memory store")
    func countsRunningTasksInMemory() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        try seed(container.mainContext)
        #expect(AppUpdateSafety.runningTaskCount(in: container.mainContext) == 2)
    }

    @Test("A running task in the store blocks an update even when the queue is idle")
    func runningTaskBlocksInstallWithIdleQueue() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        try seed(container.mainContext)
        #expect(AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 0,
            activeTaskCount: 0,
            runningTaskCount: AppUpdateSafety.runningTaskCount(in: container.mainContext)
        ))
    }

    @Test("A store with no running tasks does not block")
    func noRunningTasksDoesNotBlock() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        #expect(AppUpdateSafety.runningTaskCount(in: container.mainContext) == 0)
    }

    @Test("A context that holds the rows counts them without fetching the open set")
    func registeredRowsAreCountedWithoutAFetch() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try seed(context)
        // A context registers a row only while something holds it, which is
        // what the sidebar's snapshot does for every task in the window.
        let held = try context.fetch(FetchDescriptor<AgentTask>())
        #expect(try AppUpdateSafety.registeredRunningTaskCount(in: context) == 2)
        #expect(try AppUpdateSafety.fetchedRunningTaskCount(in: context) == 2)
        withExtendedLifetime(held) {}
    }

    @Test("Rows nothing holds any more are fetched, not assumed")
    func releasedRowsFallBackToTheFetch() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        try seed(context)
        #expect(AppUpdateSafety.heldRunningTaskCount(in: context) == 2)
    }

    @Test("A context that has not loaded the rows falls back to fetching them")
    func unloadedContextFallsBackToTheFetch() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(container.mainContext)
        let fresh = ModelContext(container)
        #expect(try AppUpdateSafety.registeredRunningTaskCount(in: fresh) == nil)
        #expect(AppUpdateSafety.heldRunningTaskCount(in: fresh) == 2)
    }

    @Test("Unsaved changes count the same way on both paths")
    func unsavedChangesMatchTheFetch() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        context.autosaveEnabled = false
        try seed(context)
        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        let workspace = try #require(tasks.first?.workspace)
        // The saved row of the task reopened below carries a completion date,
        // so only the context's pending change can make it count.
        let reopened = try #require(tasks.first { $0.status == .completed })
        reopened.completedAt = Date()
        try context.save()

        // Started but not saved yet.
        let started = AgentTask(title: "started", goal: "g", workspace: workspace)
        started.status = .running
        context.insert(started)
        #expect(context.insertedModelsArray.contains { $0.persistentModelID == started.persistentModelID })
        // Reopened but not saved yet.
        reopened.status = .running
        reopened.completedAt = nil
        // Finished but not saved yet.
        let finished = try #require(tasks.first { $0.status == .running && $0 !== reopened })
        finished.status = .completed
        finished.completedAt = Date()
        // Deleted but not saved yet.
        let deleted = try #require(tasks.first { $0.status == .running && $0 !== reopened && $0 !== finished })
        context.delete(deleted)

        // The two seeded running tasks are finished and deleted; the two that
        // count are the unsaved insert and the unsaved reopen.
        #expect(try AppUpdateSafety.registeredRunningTaskCount(in: context) == 2)
        #expect(try AppUpdateSafety.fetchedRunningTaskCount(in: context) == 2)
        #expect(AppUpdateSafety.heldRunningTaskCount(in: context) == 2)
        #expect(AppUpdateSafety.runningTaskCount(in: context) == 2)
    }

    @Test("The install decision sees a task another context saved as running")
    func installDecisionSeesAnotherContextsSave() throws {
        let (container, root) = try onDiskContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        context.autosaveEnabled = false
        try seed(context)
        // The window holds every row, as the sidebar does.
        let held = try context.fetch(FetchDescriptor<AgentTask>())
        #expect(AppUpdateSafety.runningTaskCount(in: context) == 2)

        // A worker's own context starts a task and saves.
        let worker = ModelContext(container)
        worker.autosaveEnabled = false
        let draft = try #require(try worker.fetch(FetchDescriptor<AgentTask>()).first { $0.status == .draft })
        draft.status = .running
        try worker.save()

        // The gate asks the store, so it cannot be answered from a held row
        // that still says `.draft`.
        #expect(AppUpdateSafety.runningTaskCount(in: context) == 3)
        #expect(AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 0,
            activeTaskCount: 0,
            runningTaskCount: AppUpdateSafety.runningTaskCount(in: context)
        ))
        withExtendedLifetime(held) {}
    }

    @Test("ContentView delegates to the tested count instead of an enum predicate")
    func contentViewUsesTheCompanionCount() throws {
        let source = try String(
            contentsOf: TestRepositoryRoot.resolve().appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("AppUpdateSafety.runningTaskCount(in: modelContext)"))
        #expect(!source.contains("task.status == runningStatus"))
        // The install hooks ask the store; only the window's own bookkeeping
        // may read held rows.
        let gate = try #require(source.range(of: "private func isUpdateBlockedNow() -> Bool {"))
        let gateBody = source[gate.upperBound...].prefix(400)
        #expect(gateBody.contains("runningTaskCount: fetchRunningTaskCount()"))
        let install = try #require(source.range(of: "private func prepareForAppUpdateInstall() -> Bool {"))
        #expect(source[install.upperBound...].prefix(120).contains("runningTaskCount = fetchRunningTaskCount()"))
    }
}
