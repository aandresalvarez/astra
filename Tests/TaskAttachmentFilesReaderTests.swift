import Foundation
import ASTRACore
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Task attachment Files history")
@MainActor
struct TaskAttachmentFilesReaderTests {
    @Test("Files retains follow-up attachments outside the transcript window and ignores agent quotes")
    func attachmentsOutliveTranscriptWindow() throws {
        let container = try ModelContainer(for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let task = AgentTask(title: "Follow-up", goal: "Inspect files")
        context.insert(task)
        let message = TaskEvent(task: task, type: "user.message", payload: "What is this?")
        message.timestamp = .distantPast
        TaskEventInsertionService.insert(message, attachmentPaths: ["/missing/input.pdf", "/missing/folder"], into: context)
        for index in 0..<1_205 {
            context.insert(TaskEvent(task: task, type: "system.info", payload: "\(index)"))
        }
        context.insert(TaskEvent(task: task, type: "agent.response",
            payload: "Attached files:\n- /tmp/agent-quote.txt"))
        context.insert(TaskEvent(task: task, type: "user.message",
            payload: "Again\n\nAttached files:\n- /missing/input.pdf\n- /tmp/legacy.txt"))
        let otherTask = AgentTask(title: "Other", goal: "Other")
        context.insert(otherTask)
        context.insert(TaskEvent(task: otherTask, type: "user.message",
            payload: "Attached files:\n- /tmp/other.txt"))
        try context.save()

        let paths = try TaskAttachmentFilesReader.paths(scope: TaskAttachmentHistoryScope(task: task), modelContext: ModelContext(container))
        #expect(paths == ["/missing/input.pdf", "/missing/folder", "/tmp/legacy.txt"])
        #expect(task.inputs.isEmpty)
        let presentation = TaskFilesPopoverPresentation(
            items: TaskAttachmentFilesReader.merging(paths: paths, with: [TaskFileItem(path: paths[0], source: "input")]),
            inputs: [])
        #expect(presentation.fileCount == 3)
        #expect(presentation.otherFiles.map(\.path) == paths)
    }

    @Test("Imported copies with identical UUIDs keep their attachment histories separate")
    func importedCopiesKeepAttachmentsSeparate() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let first = AgentTask(title: "Original", goal: "Original")
        let copy = AgentTask(title: "Imported", goal: "Imported")
        copy.id = first.id
        context.insert(first); context.insert(copy)
        context.insert(TaskEvent(task: first, type: "user.message", payload: "Attached files:\n- /tmp/original-533.txt"))
        context.insert(TaskEvent(task: copy, type: "user.message", payload: "Attached files:\n- /tmp/copy-533.txt"))
        try context.save()
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        #expect(try TaskAttachmentFilesReader.paths(scope: TaskAttachmentHistoryScope(task: first), modelContext: reader) == ["/tmp/original-533.txt"])
        #expect(try TaskAttachmentFilesReader.paths(scope: TaskAttachmentHistoryScope(task: copy), modelContext: reader) == ["/tmp/copy-533.txt"])
    }

    @Test("Header reads run changes and generated files only from its persisted owner")
    func importedCopyHeaderFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("header-copy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let a = AgentTask(title: "A", goal: "A"), b = AgentTask(title: "B", goal: "B")
        b.id = a.id
        context.insert(a); context.insert(b)
        for (task, name) in [(a, "a.md"), (b, "b.md")] {
            let path = root.appendingPathComponent(name).path
            try name.write(toFile: path, atomically: true, encoding: .utf8)
            let run = TaskRun(task: task)
            run.appendFileChange(StoredFileChange(path: path, changeType: StoredFileChangeKind.write.rawValue,
                content: name, oldString: nil, newString: nil, timestamp: Date()))
            context.insert(run)
        }
        try context.save()
        for (task, name) in [(a, "a.md"), (b, "b.md")] {
            let items = try TaskHeaderFilesReader.items(scope: TaskAttachmentHistoryScope(task: task), inputs: [],
                taskFolder: "", workspacePath: root.path, modelContext: ModelContext(container))
            #expect(items.map(\.path) == [root.appendingPathComponent(name).path])
        }
    }

    @Test("A follow-up folder with a file extension stays a folder in Files")
    func followUpFolderKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-followup-folder-\(UUID())")
        let folder = root.appendingPathComponent("docs.html")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(TaskAttachmentFilesReader.merging(paths: [folder.path], with: []).first)
        #expect(item.isDirectory)
        #expect(item.destination == nil)
        let task = AgentTask(title: "Follow-up", goal: "Inspect")
        let roots = WorkspaceFileIndexService.roots(workspace: nil, task: task, additionalInputPaths: [folder.path, folder.path])
        #expect(roots.filter { $0.path == folder.path }.count == 1)
        #expect(roots.first { $0.path == folder.path }?.isDirectory == true)
    }
}
