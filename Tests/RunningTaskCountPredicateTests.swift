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

    @Test("ContentView delegates to the tested count instead of an enum predicate")
    func contentViewUsesTheCompanionCount() throws {
        let source = try String(
            contentsOf: TestRepositoryRoot.resolve().appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("AppUpdateSafety.runningTaskCount(in: modelContext)"))
        #expect(!source.contains("task.status == runningStatus"))
    }
}
