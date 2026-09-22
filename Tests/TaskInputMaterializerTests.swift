import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Covers keeping pasted attachments alive: recognising a composer temp file,
/// copying a new task's into the task folder before launch, and swapping a
/// follow-up's for a durable copy before the message is sent.
@Suite("Task input materializer")
@MainActor
struct TaskInputMaterializerTests {
    private func temporaryFile(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-materializer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Predicate

    @Test("Composer paste and drop files in the temp directory are ephemeral")
    func recognisesComposerTempAttachments() {
        #expect(EphemeralComposerAttachment.isEphemeralPath(temporaryFile("astra_paste_1234ABCD.txt")))
        #expect(EphemeralComposerAttachment.isEphemeralPath(temporaryFile("astra_paste_1234ABCD.json")))
        #expect(EphemeralComposerAttachment.isEphemeralPath(temporaryFile("astra_drop_1234ABCD.png")))
        // Surrounding whitespace comes from prompt-projected paths.
        #expect(EphemeralComposerAttachment.isEphemeralPath("  \(temporaryFile("astra_paste_1234ABCD.txt"))\n"))
    }

    @Test("The /var and /private/var spellings of the temp directory compare equal")
    func resolvesTemporaryDirectorySymlinks() {
        let resolvedRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath().path
        let resolvedSpelling = (resolvedRoot as NSString).appendingPathComponent("astra_paste_1234ABCD.txt")
        #expect(EphemeralComposerAttachment.isEphemeralPath(resolvedSpelling))
        #expect(EphemeralComposerAttachment.isEphemeralPath(temporaryFile("astra_paste_1234ABCD.txt")))
    }

    @Test("Prose, relative paths, user files and nested temp files are never ephemeral")
    func rejectsEverythingElse() {
        #expect(!EphemeralComposerAttachment.isEphemeralPath("Previous task output (Summarize):\nsome prose"))
        #expect(!EphemeralComposerAttachment.isEphemeralPath("astra_paste_1234ABCD.txt"))
        #expect(!EphemeralComposerAttachment.isEphemeralPath("/Users/someone/Documents/astra_paste_1234ABCD.txt"))
        #expect(!EphemeralComposerAttachment.isEphemeralPath(temporaryFile("report.pdf")))
        #expect(!EphemeralComposerAttachment.isEphemeralPath(temporaryFile("nested/astra_paste_1234ABCD.txt")))
        #expect(!EphemeralComposerAttachment.isEphemeralPath(""))
    }

    // MARK: - Materializer

    @Test("Existing ephemeral inputs are copied into the task folder and rewritten in place")
    func materializesEphemeralInputs() throws {
        let fm = FileManager.default
        let root = try makeWorkspaceRoot()
        defer { try? fm.removeItem(at: root) }

        let paste = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        try "pasted queries".write(toFile: paste, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: paste) }
        let userFile = root.appendingPathComponent("notes.md").path
        try "user notes".write(toFile: userFile, atomically: true, encoding: .utf8)
        let purged = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        let prose = "Previous task output (Summarize):\nsome prose"

        let workspace = Workspace(name: "Materialize", primaryPath: root.path)
        let task = AgentTask(title: "Review", goal: "Review the paste", workspace: workspace)
        task.inputs = [paste, userFile, prose, purged]
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(!folder.isEmpty)

        let outcome = TaskInputMaterializer.materialize(task: task, taskFolder: folder)

        let durable = (folder as NSString)
            .appendingPathComponent(TaskInputMaterializer.inputsFolderName)
            .appending("/" + (paste as NSString).lastPathComponent)
        #expect(outcome.materialized == [durable])
        #expect(outcome.alreadyMissing == [purged])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.didChange)
        // Order is preserved; only the ephemeral entry that still existed moved.
        #expect(task.inputs == [durable, userFile, prose, purged])
        #expect(try String(contentsOfFile: durable, encoding: .utf8) == "pasted queries")
        // The temp original is left for autosave drafts that still point at it.
        #expect(fm.fileExists(atPath: paste))
        // The copy lands via staging + rename; nothing partial is left behind.
        let inputsFolder = (folder as NSString).appendingPathComponent(TaskInputMaterializer.inputsFolderName)
        #expect(try fm.contentsOfDirectory(atPath: inputsFolder) == [(paste as NSString).lastPathComponent])

        // A second launch finds nothing ephemeral left to move.
        let again = TaskInputMaterializer.materialize(task: task, taskFolder: folder)
        #expect(!again.didChange)
        #expect(again.materialized.isEmpty)
        #expect(again.alreadyMissing == [purged])
        #expect(task.inputs == [durable, userFile, prose, purged])
    }

    @Test("A durable copy left by an unsaved launch is adopted once the temp source is gone")
    func adoptsExistingDurableCopy() throws {
        let fm = FileManager.default
        let root = try makeWorkspaceRoot()
        defer { try? fm.removeItem(at: root) }
        let purged = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        let workspace = Workspace(name: "Adopt", primaryPath: root.path)
        let task = AgentTask(title: "Review", goal: "Review the paste", workspace: workspace)
        task.inputs = [purged]
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let inputsFolder = (folder as NSString).appendingPathComponent(TaskInputMaterializer.inputsFolderName)
        try fm.createDirectory(atPath: inputsFolder, withIntermediateDirectories: true)
        let durable = (inputsFolder as NSString).appendingPathComponent((purged as NSString).lastPathComponent)
        try "copied earlier".write(toFile: durable, atomically: true, encoding: .utf8)

        let outcome = TaskInputMaterializer.materialize(task: task, taskFolder: folder)

        #expect(outcome.materialized == [durable])
        #expect(outcome.alreadyMissing.isEmpty)
        #expect(task.inputs == [durable])
    }

    @Test("A task with no folder or no ephemeral inputs is left untouched")
    func leavesOrdinaryTasksAlone() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userFile = root.appendingPathComponent("brief.md").path
        try "brief".write(toFile: userFile, atomically: true, encoding: .utf8)

        let task = AgentTask(title: "Plain", goal: "No pastes")
        task.inputs = [userFile, "inline context"]

        let noFolder = TaskInputMaterializer.materialize(task: task, taskFolder: "")
        #expect(noFolder.isEmpty)
        #expect(task.inputs == [userFile, "inline context"])

        let withFolder = TaskInputMaterializer.materialize(task: task, taskFolder: root.path)
        #expect(withFolder.isEmpty)
        #expect(task.inputs == [userFile, "inline context"])
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(TaskInputMaterializer.inputsFolderName).path
        ))
    }

    // MARK: - Follow-up attachments

    @Test("A follow-up paste is copied into the task folder and the sent message names the copy")
    func followUpPasteBecomesDurable() throws {
        let fm = FileManager.default
        let root = try makeWorkspaceRoot()
        defer { try? fm.removeItem(at: root) }
        let pasteName = "astra_paste_\(UUID().uuidString.prefix(8)).png"
        let paste = temporaryFile(pasteName)
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47])
        try pngHeader.write(to: URL(fileURLWithPath: paste))
        defer { try? fm.removeItem(atPath: paste) }
        let userFile = root.appendingPathComponent("brief.md").path
        try "brief".write(toFile: userFile, atomically: true, encoding: .utf8)

        let workspace = Workspace(name: "Follow-up", primaryPath: root.path)
        let task = AgentTask(title: "Review", goal: "Review the screenshot", workspace: workspace)

        let paths = TaskInputMaterializer.durableAttachmentPaths([paste, userFile], for: task)

        let inputsFolder = (try TaskWorkspaceAccess(task: task).ensureTaskFolder() as NSString)
            .appendingPathComponent(TaskInputMaterializer.inputsFolderName)
        let durable = (inputsFolder as NSString).appendingPathComponent(pasteName)
        #expect(paths == [durable, userFile])
        #expect(fm.contents(atPath: durable) == pngHeader)
        // A follow-up's attachments belong to its message, not to the task's inputs.
        #expect(task.inputs.isEmpty)
        // The temp original is left for autosave drafts that still point at it.
        #expect(fm.fileExists(atPath: paste))

        // The launch reads attachments back out of the persisted text: it must find the copy.
        let message = TaskComposerCoordinator.composedMessage(messageText: "What changed here?", attachedFiles: paths)
        #expect(AgentRuntimeAttachmentProjection.attachmentBlockPaths(in: message) == [durable, userFile])
        #expect(!message.contains(paste))

        // Sending again, e.g. after a failed send, reuses the copy instead of making another.
        #expect(TaskInputMaterializer.durableAttachmentPaths([paste, userFile], for: task) == [durable, userFile])
        #expect(try fm.contentsOfDirectory(atPath: inputsFolder) == [pasteName])
    }

    @Test("Follow-up attachments that can't be made durable keep their original paths")
    func followUpAttachmentsFallBackToOriginalPaths() throws {
        let fm = FileManager.default
        let root = try makeWorkspaceRoot()
        defer { try? fm.removeItem(at: root) }

        // Already purged, with no earlier copy to adopt: nothing to copy.
        let purged = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        let workspace = Workspace(name: "Purged", primaryPath: root.path)
        let task = AgentTask(title: "Review", goal: "Review the paste", workspace: workspace)
        #expect(TaskInputMaterializer.durableAttachmentPaths([purged], for: task) == [purged])

        // Without a workspace there is no task folder to copy into.
        let paste = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        try "pasted".write(toFile: paste, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: paste) }
        let detached = AgentTask(title: "Loose", goal: "No workspace")
        #expect(TaskInputMaterializer.durableAttachmentPaths([paste], for: detached) == [paste])

        // Ordinary paths never touch the task folder at all.
        let userFile = root.appendingPathComponent("notes.md").path
        #expect(TaskInputMaterializer.durableAttachmentPaths([userFile, "inline context"], for: task)
            == [userFile, "inline context"])
    }
}
