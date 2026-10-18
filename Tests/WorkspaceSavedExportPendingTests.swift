import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@MainActor
@Suite("Saved export pending obligations", .serialized)
struct WorkspaceSavedExportPendingTests {
    private func fixture() throws -> (URL, ModelContainer, Workspace, AgentTask) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-export-obligations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"))])
        container.mainContext.autosaveEnabled = false
        let workspace = Workspace(name: "Committed A", primaryPath: root.path)
        let task = AgentTask(title: "Committed task", goal: "Synthetic", workspace: workspace)
        container.mainContext.insert(task)
        try container.mainContext.save()
        return (root, container, workspace, task)
    }

    private func mirror(_ root: URL) throws -> WorkspaceConfigManager.WorkspaceConfig {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self,
            from: Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))))
    }

    @Test("An unrelated workspace save preserves A's queued recovery mirror",
          arguments: ["workspace", "task", "run", "event", "delete-event", "delete-task", "delete-workspace", "app"])
    func unrelatedSave(change: String) async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let other = Workspace(name: "B", primaryPath: root.appendingPathComponent("B").path)
        let task = AgentTask(title: "B task", goal: "Synthetic", workspace: other)
        let run = TaskRun(task: task)
        let event = TaskEvent(task: task, type: "agent.response", payload: "B event", run: run)
        let app = WorkspaceApp(workspaceID: other.id, logicalID: "fixture", name: "B app",
            manifestRelativePath: "manifest.json", appDirectoryRelativePath: "app", manifestDigest: "fixture")
        context.insert(task); context.insert(run); context.insert(event); context.insert(app)
        try context.save()
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        switch change {
        case "workspace": other.name = "B changed"
        case "task": task.title = "B changed"
        case "run": run.tokensUsed = 42
        case "event": event.payload = "B changed"
        case "delete-event": context.delete(event)
        case "delete-task": SwiftDataDeletionPreparation.prepare(task); context.delete(task)
        case "delete-workspace": SwiftDataDeletionPreparation.prepare(other); context.delete(other)
        default: app.name = "B changed"
        }
        // No suspension before this commit: A's export is still queued.
        try context.save()
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket))
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        #expect(try mirror(root).name == "Committed A")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
    }

    @Test("A task moved out of A still invalidates A's earlier projection")
    func moveInvalidatesBothOwners() throws {
        let (root, container, workspace, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let other = Workspace(name: "B", primaryPath: root.appendingPathComponent("B").path)
        context.insert(other); try context.save()
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        task.workspace = other
        try context.save()
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(ticket))
    }

    @Test("Unsaved debounce and failing flush preserve the last committed projection",
          arguments: ["debounce", "flush", "debounce-flush"])
    func replacementMustCommitFirst(mode: String) async throws {
        let (root, seed, original, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let readOnly = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"), allowsSave: false)])
        let context = readOnly.mainContext
        context.autosaveEnabled = false
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let id = original.id
        let workspace = try #require(context.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        workspace.name = "Uncommitted replacement"
        if mode != "flush" {
            WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: context,
                delayNanoseconds: 500_000_000)
        }
        if mode != "debounce" {
            WorkspacePersistenceCoordinator.flushPendingExport(workspace: workspace, modelContext: context)
        }
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: id)
        #expect(try mirror(root).name == "Committed A")
        withExtendedLifetime(seed) {}
    }

    @Test("A failed termination save exports committed rows and paths rather than unsaved edits", arguments: [false, true])
    func failedTerminationSave(movePath: Bool) throws {
        let (root, seed, original, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let readOnly = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"), allowsSave: false)])
        let context = readOnly.mainContext
        context.autosaveEnabled = false
        let id = original.id
        let workspace = try #require(context.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        workspace.name = "Never committed"
        let uncommittedPath = root.appendingPathComponent("never-saved")
        if movePath { workspace.primaryPath = uncommittedPath.path }
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1)
        #expect(try mirror(root).name == "Committed A")
        #expect(!FileManager.default.fileExists(atPath: uncommittedPath.path))
        withExtendedLifetime(seed) {}
    }

    @Test("A global definition invalidates only workspaces that use it, including lowercase IDs",
          arguments: ["skill", "connector", "tool"], [false, true])
    func globalDefinitionScope(kind: String, used: Bool) async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let skill = Skill(name: "Global"); skill.isGlobal = true
        let connector = Connector(name: "Global"); connector.isGlobal = true
        let tool = LocalTool(name: "Global"); tool.isGlobal = true
        context.insert(skill); context.insert(connector); context.insert(tool)
        if used {
            switch kind {
            case "skill": workspace.enabledGlobalSkillIDs = [skill.id.uuidString.lowercased()]
            case "connector": workspace.enabledGlobalConnectorIDs = [connector.id.uuidString.lowercased()]
            default: workspace.enabledGlobalToolIDs = [tool.id.uuidString.lowercased()]
            }
        }
        try context.save()
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        switch kind {
        case "skill": skill.name = "Changed"
        case "connector": connector.name = "Changed"
        default: tool.name = "Changed"
        }
        try context.save()
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket) == !used)
        if !used {
            await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
            #expect(try mirror(root).name == "Committed A")
        }
    }

    @Test("Changing an app's flat workspaceID invalidates both its old and new owners")
    func flatOwnerMove() throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let other = Workspace(name: "B", primaryPath: root.appendingPathComponent("B").path)
        try FileManager.default.createDirectory(atPath: other.primaryPath, withIntermediateDirectories: true)
        let app = WorkspaceApp(workspaceID: workspace.id, logicalID: "fixture", name: "Moved app",
            manifestRelativePath: "manifest.json", appDirectoryRelativePath: "app", manifestDigest: "fixture")
        context.insert(other); context.insert(app); try context.save()
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: other, modelContext: context))
        let first = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        let second = WorkspaceAutoExportGate.shared.readTicket(for: other.id.uuidString)
        try #require(second.revision > 0)
        #expect(WorkspaceAutoExportGate.shared.isCurrent(first))
        app.workspaceID = other.id
        try context.save()
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(first))
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(second))
    }

    @Test("Request ledger changes resolve their scalar task owner before invalidating a mirror",
          arguments: ["unrelated", "related", "delete", "move"])
    func requestScope(change: String) async throws {
        let (root, container, workspace, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let other = Workspace(name: "B", primaryPath: root.appendingPathComponent("B").path)
        let otherTask = AgentTask(title: "Other task", goal: "Synthetic", workspace: other)
        context.insert(otherTask)
        let request = TaskTurnRequest(task: change == "unrelated" ? otherTask : task,
            messageEventID: UUID(), sequence: 1)
        context.insert(request); try context.save()
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        switch change {
        case "delete": context.delete(request)
        case "move": request.taskID = otherTask.id
        default: request.state = .cancelled
        }
        try context.save()
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket) == (change == "unrelated"))
        if change == "unrelated" {
            await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
            #expect(try mirror(root).name == "Committed A")
        }
    }

    @Test("An unsaved insert deleted before its first commit does not fault a nonexistent old row")
    func insertedThenDeleted() async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        let other = Workspace(name: "B", primaryPath: root.appendingPathComponent("B").path)
        let transient = AgentTask(title: "Never saved", goal: "Synthetic", workspace: other)
        context.insert(transient); context.delete(transient)
        try context.save()
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket))
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        #expect(try mirror(root).name == "Committed A")
    }

    @Test("A successful debounce replaces the older saved projection and finishes both obligations")
    func successfulReplacement() async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        workspace.name = "Committed replacement"
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: context,
            delayNanoseconds: 50_000_000)
        for _ in 0..<4 where WorkspacePersistenceCoordinator.pendingExportWorkspaceCount > 0 {
            await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        }
        #expect(try mirror(root).name == "Committed replacement")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
    }

    @Test("Termination discards a replaced or removed store before faulting its old workspace models")
    func removedStoreAtTermination() throws {
        let (root, container, original, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        original.primaryPath = workspaceRoot.path
        try container.mainContext.save()
        let source = ModelContext(container)
        source.autosaveEnabled = false
        let id = original.id
        let workspace = try #require(source.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: source))
        // Simulate store replacement while a closed owner's deferred release
        // still keeps the source context alive. Do not resolve its task graph.
        try FileManager.default.removeItem(at: root)
        // Workspace files survive store replacement in production. Recreate
        // that folder so a missing workspace path cannot hide this boundary.
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let replacement = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: replacement.mainContext) == 0)
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("source.store").path))
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.workspaceConfigFile(for: workspaceRoot.path)))
        withExtendedLifetime(source) {}
    }
}
