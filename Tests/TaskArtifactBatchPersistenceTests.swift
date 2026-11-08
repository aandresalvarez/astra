import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Batched artifact persistence", .serialized)
@MainActor
struct TaskArtifactBatchPersistenceTests {
    @Test("Prefetching does not borrow artifacts from an imported task with the same UUID")
    func duplicateTaskUUIDsStayIsolated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(url: root.appendingPathComponent("duplicate-ids.store")))
        let context = ModelContext(container)
        let first = AgentTask(title: "Original", goal: "Produce files")
        let second = AgentTask(title: "Imported copy", goal: "Produce files")
        second.id = first.id
        context.insert(first)
        context.insert(second)
        let files = try makeFiles(count: 1, root: root)
        let original = Artifact(task: first, type: "txt", path: files[0].path, version: 7)
        first.artifacts = [original]
        try context.save()

        let summary = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: second, modelContext: context)
        #expect(summary.createdArtifacts.count == 1)
        #expect(summary.createdArtifacts.first?.version == 1)
        #expect(first.artifacts.map(\.id) == [original.id])
        #expect(second.artifacts.count == 1)
        #expect(second.artifacts.first?.id != original.id)
        #expect(second.artifacts.first?.task?.persistentModelID == second.persistentModelID)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Artifact>()) == 2)
    }

    @Test("A batch preserves existing rows, deduplicates paths, and persists both relationship directions")
    func batchSurvivesReopeningAndCascadeDeletion() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("artifacts.store")
        let configuration = ModelConfiguration(url: store)
        let taskID: UUID = try autoreleasepool {
            let container = try ModelContainer(for: ASTRASchema.current, configurations: configuration)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let task = AgentTask(title: "Synthetic batch", goal: "Produce files")
            context.insert(task)
            let existing = Artifact(task: task, type: "txt", path: root.appendingPathComponent("existing.txt").path, version: 7)
            task.artifacts = [existing]
            try context.save()

            let files = try makeFiles(count: 256, root: root)
            let duplicate = TaskOutputDiscoveredFile(
                path: root.appendingPathComponent("sub/../output-0.txt").path,
                relativePath: "output-0.txt", type: "txt"
            )
            let summary = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(
                files + [files[0], duplicate], for: task, modelContext: context
            )
            #expect(summary.createdArtifacts.count == files.count)
            #expect(summary.currentArtifacts.count == files.count)
            #expect(summary.staleArtifacts.map(\.id) == [existing.id])
            #expect(summary.duplicateArtifacts.isEmpty)
            #expect(existing.version == 7)
            #expect(task.artifacts.count == files.count + 1)
            #expect(Set(task.artifacts.map(\.id)).count == files.count + 1)
            #expect(summary.createdArtifacts.allSatisfy { $0.task === task && $0.version == 1 })
            try context.save()
            return task.id
        }

        try autoreleasepool {
            let container = try ModelContainer(for: ASTRASchema.current, configurations: configuration)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let task = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == taskID })
            let artifacts = try context.fetch(FetchDescriptor<Artifact>())
            #expect(task.artifacts.count == 257)
            #expect(artifacts.count == 257)
            #expect(artifacts.allSatisfy { $0.task?.id == taskID })
            let summary = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(
                try makeFiles(count: 256, root: root), for: task, modelContext: context
            )
            #expect(summary.createdArtifacts.isEmpty)
            #expect(summary.duplicateArtifacts.isEmpty)
            context.delete(task)
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<Artifact>()) == 0)
        }
    }

    enum ContextMode: CaseIterable { case detached, attached, insertGraph }

    @Test("Batches support detached tasks and optional contexts", arguments: ContextMode.allCases)
    func optionalContext(mode: ContextMode) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let task = AgentTask(title: "Synthetic optional context", goal: "Produce files")
        if mode == .attached { context.insert(task) }
        let files = try makeFiles(count: 32, root: root)
        let result = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: task, modelContext: mode == .insertGraph ? context : nil)
        #expect(result.createdArtifacts.count == 32)
        #expect(task.artifacts.count == 32)
        #expect(task.artifacts.allSatisfy { $0.task === task })
        #expect(TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: task).createdArtifacts.isEmpty)
        if mode != .detached {
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<Artifact>()) == 32)
        }
    }

    @Test("Rollback removes a complete new batch while preserving previously saved rows")
    func rollbackAndRetry() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(url: root.appendingPathComponent("rollback.store")))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let task = AgentTask(title: "Synthetic rollback", goal: "Produce files")
        context.insert(task)
        let old = Artifact(task: task, type: "txt", path: root.appendingPathComponent("old.txt").path)
        task.artifacts = [old]
        try context.save()
        let oldID = old.id
        let files = try makeFiles(count: 32, root: root)
        _ = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: task, modelContext: context)
        context.rollback()
        #expect(try context.fetchCount(FetchDescriptor<Artifact>()) == 1)
        // SwiftData retains the old model's cached relationship after rollback,
        // including on unmodified main. Verify durable rollback and retry using
        // a fresh context, as a reopened task would, rather than that stale graph.
        let retryContext = ModelContext(container)
        let reopened = try #require(try retryContext.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(reopened.artifacts.map(\.id) == [oldID])
        let retry = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: reopened, modelContext: retryContext)
        #expect(retry.createdArtifacts.count == files.count)
        try retryContext.save()
        #expect(try retryContext.fetchCount(FetchDescriptor<Artifact>()) == files.count + 1)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-artifact-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFiles(count: Int, root: URL) throws -> [TaskOutputDiscoveredFile] {
        try (0..<count).map { index in
            let name = "output-\(index).txt"
            let url = root.appendingPathComponent(name)
            try "Synthetic artifact \(index)".write(to: url, atomically: true, encoding: .utf8)
            return TaskOutputDiscoveredFile(path: url.path, relativePath: name, type: "txt")
        }
    }
}
