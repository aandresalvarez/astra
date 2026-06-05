import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskArtifactPersistenceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task Artifact Persistence")
@MainActor
struct TaskArtifactPersistenceServiceTests {
    @Test("reconciliation promotes discovered task output files idempotently")
    func reconciliationPromotesDiscoveredTaskOutputFilesIdempotently() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskArtifactPersistenceContainer()
        let context = ModelContext(container)
        let task = makeTask(root: root, context: context, title: "Create HTML")

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try "<!doctype html><html><body>Artifact</body></html>".write(
            toFile: indexPath,
            atomically: true,
            encoding: .utf8
        )

        let first = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(for: task, modelContext: context)
        #expect(first.status == .artifactsChanged)
        #expect(first.auditFields["result"] == "artifactsChanged")
        #expect(first.auditFields["created_artifact_count"] == "1")
        #expect(first.createdArtifacts.map(\.path) == [indexPath])
        #expect(first.currentArtifacts.map(\.path).contains(indexPath))
        #expect(first.staleArtifacts.isEmpty)
        #expect(first.duplicateArtifacts.isEmpty)
        #expect(task.artifacts.filter { $0.path == indexPath }.count == 1)

        let second = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(for: task, modelContext: context)
        #expect(second.status == .unchanged)
        #expect(second.auditFields["result"] == "unchanged")
        #expect(second.createdArtifacts.isEmpty)
        #expect(second.currentArtifacts.map(\.path).contains(indexPath))
        #expect(second.duplicateArtifacts.isEmpty)
        #expect(task.artifacts.filter { $0.path == indexPath }.count == 1)
    }

    @Test("reconciliation reports stale and duplicate artifact rows")
    func reconciliationReportsStaleAndDuplicateArtifactRows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskArtifactPersistenceContainer()
        let context = ModelContext(container)
        let task = makeTask(root: root, context: context, title: "Repair Artifacts")

        let currentPath = (root as NSString).appendingPathComponent("current.md")
        try "# Current".write(toFile: currentPath, atomically: true, encoding: .utf8)
        let stalePath = (root as NSString).appendingPathComponent("missing.md")
        let first = Artifact(task: task, type: "markdown", path: currentPath, version: 1)
        let duplicate = Artifact(task: task, type: "markdown", path: currentPath, version: 2)
        let stale = Artifact(task: task, type: "markdown", path: stalePath, version: 1)
        context.insert(first)
        context.insert(duplicate)
        context.insert(stale)
        task.artifacts.append(contentsOf: [first, duplicate, stale])

        let summary = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts([], for: task, modelContext: context)
        #expect(summary.status == .duplicateArtifacts)
        #expect(summary.auditFields["duplicate_artifact_count"] == "1")
        #expect(summary.auditFields["stale_artifact_count"] == "1")
        #expect(summary.createdArtifacts.isEmpty)
        #expect(summary.currentArtifacts.contains { $0.id == first.id })
        #expect(summary.currentArtifacts.contains { $0.id == duplicate.id })
        #expect(summary.staleArtifacts.map(\.id).contains(stale.id))
        #expect(summary.duplicateArtifacts.map(\.id).contains(duplicate.id))
    }

    @Test("file change artifact persistence versions through the shared service")
    func fileChangeArtifactPersistenceVersionsThroughSharedService() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskArtifactPersistenceContainer()
        let context = ModelContext(container)
        let task = makeTask(root: root, context: context, title: "Track Edits")
        let path = (root as NSString).appendingPathComponent("app.swift")
        try "let one = 1".write(toFile: path, atomically: true, encoding: .utf8)

        let write = StoredFileChange(from: FileChange(
            path: path,
            changeType: .write,
            content: "let one = 1",
            oldString: nil,
            newString: nil,
            timestamp: Date()
        ))
        let edit = StoredFileChange(from: FileChange(
            path: path,
            changeType: .edit,
            content: nil,
            oldString: "let one = 1",
            newString: "let two = 2",
            timestamp: Date()
        ))

        let first = try #require(TaskArtifactPersistenceService.persistFileChangeArtifact(write, for: task, modelContext: context))
        let second = try #require(TaskArtifactPersistenceService.persistFileChangeArtifact(edit, for: task, modelContext: context))

        #expect(write.kind == .write)
        #expect(edit.kind == .edit)
        #expect(first.version == 1)
        #expect(second.version == 2)
        #expect(task.artifacts.filter { $0.path == path }.map(\.version).sorted() == [1, 2])
    }

    @Test("deliverable verification promotes discovered artifacts")
    func deliverableVerificationPromotesDiscoveredArtifacts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskArtifactPersistenceContainer()
        let context = ModelContext(container)
        let task = makeTask(root: root, context: context, title: "Write Report", goal: "Create a report artifact")

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let reportPath = (folder as NSString).appendingPathComponent("report.md")
        try "# Report\n\nComplete.".write(toFile: reportPath, atomically: true, encoding: .utf8)

        let result = await TaskDeliverableVerificationService.evaluate(
            task: task,
            run: nil,
            modelContext: context
        )

        #expect(result.evidencePaths.contains(reportPath))
        #expect(task.artifacts.contains { $0.path == reportPath && $0.type == "markdown" })
    }

    @Test("generated file trigger observes artifact row changes")
    func generatedFileTriggerObservesArtifactRowChanges() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskArtifactPersistenceContainer()
        let context = ModelContext(container)
        let task = makeTask(root: root, context: context, title: "Refresh Shelf")

        let before = TaskGeneratedFilesTrigger(task: task, latestRun: nil)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let path = (folder as NSString).appendingPathComponent("notes.md")
        try "# Notes".write(toFile: path, atomically: true, encoding: .utf8)
        TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(for: task, modelContext: context)
        let after = TaskGeneratedFilesTrigger(task: task, latestRun: nil)

        #expect(before != after)
        #expect(TaskFileIndex.scanTaskFolder(folder).contains { $0.path == path && $0.destination == .files })
    }

    private func makeTask(
        root: String,
        context: ModelContext,
        title: String,
        goal: String = "Create a standalone artifact"
    ) -> AgentTask {
        let workspace = Workspace(name: title, primaryPath: root)
        let task = AgentTask(title: title, goal: goal, workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        return task
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-artifact-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
