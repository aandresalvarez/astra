import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Startup maintenance's third job: forgetting pasted attachments that macOS
/// has already purged from `$TMPDIR`, so a task is not haunted by a path it
/// can never satisfy again.
@Suite("Task store maintenance — purged paste inputs")
@MainActor
struct TaskStoreMaintenanceTests {
    private func temporaryFile(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test("Purged paste inputs are stripped; live pastes, user files and prose survive")
    func stripsOnlyPurgedEphemeralInputs() throws {
        let fm = FileManager.default
        let livePaste = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        try "still here".write(toFile: livePaste, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: livePaste) }
        let purgedPaste = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        let purgedDrop = temporaryFile("astra_drop_\(UUID().uuidString.prefix(8)).png")
        let userFile = "/Users/someone/Documents/removed-but-not-ours.pdf"
        let prose = "Previous task output (Summarize):\nsome prose"

        let context = try makeContext()
        let task = AgentTask(title: "Haunted", goal: "Continue")
        task.inputs = [purgedPaste, livePaste, userFile, purgedDrop, prose]
        let clean = AgentTask(title: "Clean", goal: "Nothing to do")
        clean.inputs = [userFile, prose]
        context.insert(task)
        context.insert(clean)
        try context.save()

        let removed = TaskStoreMaintenance.stripPurgedEphemeralInputs([task, clean], modelContext: context)

        #expect(removed == 2)
        // A missing *user* file is not ours to forget — only composer temp files.
        #expect(task.inputs == [livePaste, userFile, prose])
        #expect(clean.inputs == [userFile, prose])
        // The thread records what was dropped so a later run's missing context is explained.
        let note = try #require(task.events.first { $0.type == TaskEventTypes.System.info.rawValue })
        #expect(note.payload.contains((purgedPaste as NSString).lastPathComponent))
        #expect(note.payload.contains((purgedDrop as NSString).lastPathComponent))
        #expect(clean.events.isEmpty)
    }

    @Test("Maintenance adopts a durable copy instead of stripping when one exists")
    func adoptsDurableCopyInsteadOfStripping() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astra-maint-adopt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let context = try makeContext()
        let purged = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).txt")
        let workspace = Workspace(name: "Adopt", primaryPath: root.path)
        let task = AgentTask(title: "Review", goal: "Continue", workspace: workspace)
        task.inputs = [purged]
        context.insert(workspace); context.insert(task); try context.save()
        let inputsFolder = (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent("inputs")
        try fm.createDirectory(atPath: inputsFolder, withIntermediateDirectories: true)
        let durable = (inputsFolder as NSString).appendingPathComponent((purged as NSString).lastPathComponent)
        try "copied earlier".write(toFile: durable, atomically: true, encoding: .utf8)

        let removed = TaskStoreMaintenance.stripPurgedEphemeralInputs([task], modelContext: context)

        #expect(removed == 0)
        #expect(task.inputs == [durable])
        #expect(task.events.isEmpty)
    }

    @Test("Startup maintenance reports and persists the stripped count")
    func startupMaintenanceStripsAndSaves() throws {
        let context = try makeContext()
        let purgedPaste = temporaryFile("astra_paste_\(UUID().uuidString.prefix(8)).json")
        let workspace = Workspace(name: "Maintenance", primaryPath: "/tmp/astra-maintenance-\(UUID().uuidString)")
        let task = AgentTask(title: "Review queries", goal: "Review the pasted queries", workspace: workspace)
        task.status = .completed
        task.inputs = [purgedPaste, "inline context"]
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let report = TaskStoreMaintenance.runStartupMaintenance(modelContext: context)

        #expect(report.strippedPurgedInputs == 1)
        #expect(task.inputs == ["inline context"])
        #expect(task.events.contains { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.contains("pasted attachment") })
        // The task itself is untouched — this is not a prune.
        let survivors = try context.fetch(FetchDescriptor<AgentTask>())
        #expect(survivors.map(\.id) == [task.id])

        let again = TaskStoreMaintenance.runStartupMaintenance(modelContext: context)
        #expect(again.strippedPurgedInputs == 0)
    }
}
