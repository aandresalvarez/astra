import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Rail output provenance")
@MainActor
struct WorkspaceRailOutputPresentationTests {
    @Test("The real reader keeps inputs in Files but only produced files in Outputs")
    func readerProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = AgentTask(title: "Outputs", goal: "Inspect and edit synthetic files")
        context.insert(task)
        let initial = root.appendingPathComponent("initial.txt").path
        let followup = root.appendingPathComponent("followup.pdf").path
        let edited = root.appendingPathComponent("edited-input.md").path
        let generated = root.appendingPathComponent("result.html").path
        for path in [initial, followup, edited, generated] {
            try "Synthetic QA".write(toFile: path, atomically: true, encoding: .utf8)
        }
        let taskFolder = root.appendingPathComponent("task-folder")
        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        let innerInput = taskFolder.appendingPathComponent("user-provided.txt").path
        let innerAttachment = taskFolder.appendingPathComponent("followup.md").path
        for path in [innerInput, innerAttachment] {
            try "An input placed inside the task folder is still an input".write(toFile: path, atomically: true, encoding: .utf8)
        }
        let attachedFolder = taskFolder.appendingPathComponent("user-folder")
        try FileManager.default.createDirectory(at: attachedFolder, withIntermediateDirectories: true)
        let child = attachedFolder.appendingPathComponent("child.md")
        try "User folder content".write(to: child, atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("folder-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: attachedFolder)
        task.inputs = [initial, edited, innerInput]
        let event = TaskEvent(task: task, type: "user.message", payload: "Inspect the attached PDF")
        TaskEventInsertionService.insert(event, attachmentPaths: [followup, innerAttachment, alias.appendingPathComponent(".").path, root.appendingPathComponent("missing.pdf").path], into: context)
        try context.save()
        let scope = TaskAttachmentHistoryScope(task: task)
        let filesOnly = try TaskHeaderFilesReader.facts(scope: scope, inputs: task.inputs,
            taskFolder: taskFolder.path, workspacePath: root.path, modelContext: context)
        #expect(filesOnly.items.contains { $0.path == followup && $0.source == "attached" })
        #expect(WorkspaceRailOutputPresentation.facts(from: filesOnly).files.isEmpty)

        let run = TaskRun(task: task)
        run.appendHostFileChanges([StoredFileChange(path: edited, changeType: "Edit"),
                           StoredFileChange(path: generated, changeType: "Write"),
                           StoredFileChange(path: child.path, changeType: "Edit")])
        context.insert(run)
        try context.save()
        let withOutputs = try TaskHeaderFilesReader.facts(scope: scope, inputs: task.inputs,
            taskFolder: taskFolder.path, workspacePath: root.path, modelContext: context)
        let outputs = WorkspaceRailOutputPresentation.facts(from: withOutputs)
        #expect(Set(outputs.files.map(\.path)) == [edited, generated, child.path])
        #expect(outputs.files.first { $0.path == generated }?.destination == .browser)
    }

    @Test("Files and Outputs deduplicate generated paths and recorded changes through symlink aliases")
    func aliasesDescribeOneFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let file = folder.appendingPathComponent("report.md")
        try "Synthetic output".write(to: file, atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let task = AgentTask(title: "Alias", goal: "One output")
        context.insert(task)
        let run = TaskRun(task: task)
        run.appendHostFileChanges([.init(path: alias.appendingPathComponent("report.md").path, changeType: "Write")])
        context.insert(run)
        try context.save()
        let files = try TaskHeaderFilesReader.facts(scope: .init(task: task), inputs: [],
            taskFolder: folder.path, workspacePath: root.path, modelContext: context)
        #expect(files.items.count == 1)
        #expect(files.items.first?.change?.kind == .write)
        #expect(WorkspaceRailOutputPresentation.facts(from: files).files.count == 1)
    }

    @Test("Folder discovery, deletions and unknown provenance do not become Outputs")
    func outputEvidence() {
        let facts = WorkspaceRailOutputPresentation.facts(from: .init(items: [
            .init(path: "/tmp/generated.md", source: "output"),
            .init(path: "/tmp/folder", isDirectory: true, source: "output"),
            .init(path: "/tmp/deleted.md", source: "removed", change: .init(path: "/tmp/deleted.md", changeType: "removed")),
            .init(path: "/tmp/unknown.md", source: "unknown")
        ]))
        #expect(facts.files.map(\.path) == ["/tmp/generated.md"])
    }

    @Test("Identical imported metadata still triggers a new output read for its owner")
    func readKeyUsesOwner() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = AgentTask(title: "A", goal: "A")
        let second = AgentTask(title: "B", goal: "B")
        second.id = first.id; second.updatedAt = first.updatedAt
        container.mainContext.insert(first); container.mainContext.insert(second)
        try container.mainContext.save()
        #expect(WorkspaceRailOutputPresentation.ReadKey(task: first, refreshTick: 0)
                != WorkspaceRailOutputPresentation.ReadKey(task: second, refreshTick: 0))
    }
}
