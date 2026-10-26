import AppKit
import SwiftUI
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Shelf attachment history invalidation", .serialized)
@MainActor
struct ShelfAttachmentHistoryTests {
    private static var retained: [Any] = []

    private func settle(until condition: () -> Bool, turns: Int = 400) async {
        for _ in 0..<turns {
            if condition() { return }
            _ = await MainActor.run {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Only this task's attachment changes invalidate the history projection")
    func unrelatedChangesStayQuiet() {
        let taskID = UUID()
        func event(task: UUID? = nil, type: String, payload: String = "") -> DurableTaskEventInsertion {
            .init(taskID: task ?? taskID, eventID: UUID(), type: type, payload: payload, timestamp: Date())
        }
        #expect(ShelfAttachmentHistoryRefreshPolicy.affectsAttachments(event(type: "user.attachments"), taskID: taskID))
        #expect(ShelfAttachmentHistoryRefreshPolicy.affectsAttachments(
            event(type: TaskPlanConversationEventTypes.userMessage, payload: "Attached files:\n- /tmp/legacy.txt"), taskID: taskID))
        #expect(!ShelfAttachmentHistoryRefreshPolicy.affectsAttachments(event(task: UUID(), type: "user.attachments"), taskID: taskID))
        #expect(!ShelfAttachmentHistoryRefreshPolicy.affectsAttachments(event(type: "user.message", payload: "Plain text"), taskID: taskID))
        #expect(!ShelfAttachmentHistoryRefreshPolicy.affectsAttachments(
            event(type: "agent.response", payload: "Attached files:\n- /tmp/quoted.txt"), taskID: taskID))
    }

    @Test("Switching between imported copies with the same UUID refreshes the visible Files roots")
    func importedCopySelectionChangesOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-shelf-copy-\(UUID())")
        let workspaceURL = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original.txt")
        let copyURL = root.appendingPathComponent("copy.txt")
        for url in [originalURL, copyURL] { try "Synthetic".write(to: url, atomically: true, encoding: .utf8) }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Copies", primaryPath: workspaceURL.path)
        let original = AgentTask(title: "Original", goal: "Original", workspace: workspace)
        let copy = AgentTask(title: "Copy", goal: "Copy", workspace: workspace)
        copy.id = original.id
        context.insert(workspace); context.insert(original); context.insert(copy)
        for (task, path) in [(original, originalURL.path), (copy, copyURL.path)] {
            TaskEventInsertionService.insert(TaskEvent(task: task, type: "user.message", payload: "Inspect"),
                attachmentPaths: [path], into: context)
        }
        try context.save()
        let index = ShelfFileIndexController()
        let session = ShelfMarkdownSession()
        func panel(_ task: AgentTask) -> some View {
            ShelfMarkdownPanelView(session: session, fileIndex: index,
                isPinnedToTask: .constant(false), workspace: workspace, task: task).modelContainer(container)
        }
        let host = NSHostingView(rootView: panel(original))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        Self.retained.append(contentsOf: [container, context, index, session, host, window])
        defer { window.orderOut(nil); window.contentView = nil; host.removeFromSuperview() }
        await settle(until: { index.allRoots.contains { $0.path == originalURL.path } })
        #expect(index.allRoots.contains { $0.path == originalURL.path })
        #expect(!index.allRoots.contains { $0.path == copyURL.path })
        host.rootView = panel(copy)
        await settle(until: { index.allRoots.contains { $0.path == copyURL.path } })
        #expect(index.allRoots.contains { $0.path == copyURL.path })
        #expect(!index.allRoots.contains { $0.path == originalURL.path })
        // A rapid return cannot let the superseded read republish copy paths.
        host.rootView = panel(original)
        host.rootView = panel(copy)
        await settle(until: { index.allRoots.contains { $0.path == copyURL.path } })
        #expect(!index.allRoots.contains { $0.path == originalURL.path })
    }

    @Test("An open shelf receives a persisted attachment while the task status stays unchanged",
          arguments: [TaskPlanConversationEventTypes.userMessage, "user.message"])
    func attachmentAppearsWithoutLifecycleChange(messageType: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-shelf-history-\(UUID())")
        let workspaceURL = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = root.appendingPathComponent("late-attachment.txt")
        try "Synthetic attachment added while planning.".write(to: attachment, atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let workspace = Workspace(name: "Shelf", primaryPath: workspaceURL.path)
        let task = AgentTask(title: "Planning", goal: "Inspect an attachment", workspace: workspace)
        task.status = .draft
        context.insert(workspace)
        context.insert(task)
        try context.save()
        let index = ShelfFileIndexController()
        let session = ShelfMarkdownSession()
        let host = NSHostingView(rootView: ShelfMarkdownPanelView(session: session, fileIndex: index,
            isPinnedToTask: .constant(false), workspace: workspace, task: task).modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        Self.retained.append(contentsOf: [container, context, index, session, host, window])
        defer { window.orderOut(nil); window.contentView = nil; host.removeFromSuperview() }
        await settle(until: { index.revision > 0 })
        #expect(!index.allRoots.contains { $0.path == attachment.path })
        let status = task.status
        let message = TaskEvent(task: task, type: messageType, payload: "What is this?")
        TaskEventInsertionService.insert(message, attachmentPaths: [attachment.path], into: context)
        try context.save()

        await settle(until: { index.allRoots.contains { $0.path == attachment.path } })
        #expect(task.status == status)
        #expect(index.allRoots.contains { $0.path == attachment.path })
        #expect(task.inputs.isEmpty, "Follow-up attachment events remain the durable owner")
    }
}
