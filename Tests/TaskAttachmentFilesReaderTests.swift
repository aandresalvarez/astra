import Foundation
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

        let paths = try TaskAttachmentFilesReader.paths(taskID: task.id, modelContext: ModelContext(container))
        #expect(paths == ["/missing/input.pdf", "/missing/folder", "/tmp/legacy.txt"])
        #expect(task.inputs.isEmpty)
        let presentation = TaskFilesPopoverPresentation(
            items: TaskAttachmentFilesReader.merging(paths: paths, with: [TaskFileItem(path: paths[0], source: "input")]),
            inputs: [])
        #expect(presentation.fileCount == 3)
        #expect(presentation.otherFiles.map(\.path) == paths)
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
