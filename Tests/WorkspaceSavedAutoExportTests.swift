import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@MainActor
@Suite("Saved workspace auto-export", .serialized)
struct WorkspaceSavedAutoExportTests {
    private final class WeakContainer {
        weak var value: ModelContainer?
        init(_ value: ModelContainer) { self.value = value }
    }
    private func fixture(memory: Bool = false) throws -> (URL, ModelContainer, Workspace, AgentTask) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-saved-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = memory ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: root.appendingPathComponent("fixture.store"))
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [config])
        container.mainContext.autosaveEnabled = false
        let workspace = Workspace(name: "Synthetic", primaryPath: root.path)
        let task = AgentTask(title: "First", goal: "Synthetic goal", workspace: workspace)
        container.mainContext.insert(workspace)
        container.mainContext.insert(task)
        let run = TaskRun(task: task)
        container.mainContext.insert(run)
        for index in 0..<15 {
            container.mainContext.insert(TaskEvent(task: task, type: "agent.response", payload: "event \(index)", run: run))
        }
        try container.mainContext.save()
        return (root, container, workspace, task)
    }

    @Test("Projection uses saved rows, off-main for disk and serialized with edits for memory", arguments: [false, true])
    func savedProjection(memory: Bool) async throws {
        let (root, container, workspace, task) = try fixture(memory: memory)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = WorkspaceSavedAutoExport()
        let expected = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: container.mainContext))
        task.title = "Unsaved"
        let first = try #require(try await reader.prepare(container: container, workspaceID: workspace.id))
        #expect(first.ranOnMainThread == memory)
        #expect(first.config.tasks?.first?.title == "First")
        #expect(first.config.tasks?.first?.events.map(\.id) == expected.tasks?.first?.events.map(\.id))
        #expect(first.config.tasks?.first?.runs.map(\.id) == expected.tasks?.first?.runs.map(\.id))
        #expect(first.config.tasks?.first?.events.count == WorkspaceConfigManager.MirrorLimits.maxEventsPerTask)
        try container.mainContext.save()
        let second = try #require(try await reader.prepare(container: container, workspaceID: workspace.id))
        #expect(second.config.tasks?.first?.title == "Unsaved")
        #expect(first.config.tasks?.first?.title == "First")
    }

    @Test("Rapid saves coalesce and the latest durable state reaches the mirror")
    func latestSaveWins() async throws {
        let (root, container, workspace, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let old = WorkspaceAutoExportGate.shared.ticket(for: workspace.id.uuidString)
        task.title = "Second"
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: workspace, modelContext: context)
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(old))
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: mirror),
               let config = try? JSONDecoder.workspaceMirror.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: data),
               config.tasks?.first?.title == "Second" { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The latest saved state never reached the mirror")
    }

    @Test("Background projection reads legacy SSH configuration without migrating domain files")
    func projectionDoesNotMigrateConnections() async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = URL(fileURLWithPath: WorkspaceFileLayout.legacySSHConnectionsFile(for: root.path))
        let canonical = URL(fileURLWithPath: WorkspaceFileLayout.sshConnectionsFile(for: root.path))
        let connection = SSHConnection(name: "Synthetic SSH", host: "example.invalid", user: "fixture")
        try JSONEncoder().encode([connection]).write(to: legacy)
        let prepared = try #require(try await WorkspaceSavedAutoExport().prepare(container: container, workspaceID: workspace.id))
        #expect(prepared.config.sshConnections.first?.id == connection.id)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
        // An explicit SSH load still owns the existing migration behavior.
        #expect(SSHConnectionManager.load(workspacePath: root.path).first?.id == connection.id)
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Termination drains an async projection and rejects a late old write")
    func terminationSupersedesInFlightSnapshot() async throws {
        let (root, container, workspace, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let old = WorkspaceAutoExportGate.shared.ticket(for: workspace.id.uuidString)
        let prepared = try #require(try await WorkspaceSavedAutoExport().prepare(container: container, workspaceID: workspace.id))
        task.title = "At termination"
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) >= 1)
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        await WorkspaceAutoExportWriter.shared.write(prepared.config, to: mirror,
            workspaceID: workspace.id.uuidString, ticket: old)
        let config = try JSONDecoder.workspaceMirror.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: Data(contentsOf: mirror))
        #expect(config.tasks?.first?.title == "At termination")
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(old))
    }

    @Test("A later save without export invalidates the pending read", arguments: [false, true])
    func laterSaveInvalidatesProjection(rawSave: Bool) async throws {
        let (root, container, workspace, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let old = WorkspaceAutoExportGate.shared.ticket(for: workspace.id.uuidString)
        task.title = "Intermediate bookkeeping"
        if rawSave { try context.save() }
        else { #expect(WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context)) }
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(old))
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        await WorkspaceSavedAutoExport().export(container: container, workspaceID: workspace.id, url: mirror, ticket: old)
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        // The cancelled read still owes a mirror at the next explicit drain.
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) >= 1)
        #expect(FileManager.default.fileExists(atPath: mirror.path))
    }

    @Test("Cancellation rejects queued projection and write without poisoning the next request")
    func cancellationSkipsQueuedWork() async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = workspace.id
        let mirror = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: id.uuidString)
        let prepared = try #require(try await WorkspaceSavedAutoExport().prepare(container: container, workspaceID: id))
        let read = Task { await WorkspaceSavedAutoExport().export(container: container,
            workspaceID: id, url: mirror, ticket: ticket) }
        read.cancel()
        #expect(await read.value == false)
        let write = Task { await WorkspaceAutoExportWriter.shared.write(prepared.config,
            to: mirror, workspaceID: id.uuidString, ticket: ticket) }
        write.cancel()
        #expect(await write.value == false)
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        let next = WorkspaceAutoExportGate.shared.beginExport(for: id.uuidString)
        #expect(await WorkspaceAutoExportWriter.shared.write(prepared.config,
            to: mirror, workspaceID: id.uuidString, ticket: next))
        #expect(FileManager.default.fileExists(atPath: mirror.path))
    }

    @Test("An old read lease never invalidates a newer explicit snapshot")
    func newerExplicitSnapshotKeepsItsTicket() throws {
        let (root, container, workspace, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: container.mainContext))
        let newer = WorkspaceAutoExportGate.shared.beginExport(for: workspace.id.uuidString)
        task.title = "Later saved value"
        try container.mainContext.save()
        #expect(WorkspaceAutoExportGate.shared.isCurrent(newer))
        // No background writer is launched for this explicit test ticket.
        WorkspaceAutoExportGate.shared.retire(workspaceID: workspace.id.uuidString)
        WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: container.mainContext)
    }

    @Test("Deletion rejects an already prepared projection")
    func deletionRejectsLateProjection() async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = workspace.id
        let mirror = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: id.uuidString)
        let prepared = try #require(try await WorkspaceSavedAutoExport().prepare(container: container, workspaceID: id))
        WorkspaceAutoExportGate.shared.retire(workspaceID: id.uuidString)
        container.mainContext.delete(workspace)
        try container.mainContext.save()
        await WorkspaceAutoExportWriter.shared.write(prepared.config, to: mirror, workspaceID: id.uuidString, ticket: ticket)
        await WorkspaceSavedAutoExport().export(container: container, workspaceID: id, url: mirror, ticket: ticket)
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
    }

    @Test("A saved path move cannot project the new config into the old folder")
    func pathMoveRejectsOldDestination() async throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mirror = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: workspace.id.uuidString)
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        workspace.primaryPath = moved.path
        try container.mainContext.save()
        await WorkspaceSavedAutoExport().export(container: container, workspaceID: workspace.id, url: mirror, ticket: ticket)
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
    }

    @Test("Termination skips a pending workspace that was deleted")
    func terminationSkipsDeletedWorkspace() throws {
        let (root, container, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: container.mainContext))
        WorkspaceAutoExportGate.shared.retire(workspaceID: workspace.id.uuidString)
        container.mainContext.delete(workspace)
        try container.mainContext.save()
        WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: container.mainContext)
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path)))
    }

    @Test("A queued mirror does not keep its persistence owner and autosave alive", arguments: [false, true])
    func deferredMirrorReleasesItsOwner(memory: Bool) async throws {
        func enqueueAndCloseOwner() throws -> (URL, UUID, WeakContainer) {
            let (root, container, workspace, task) = try fixture(memory: memory)
            container.mainContext.autosaveEnabled = true
            let observed = WeakContainer(container)
            #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: container.mainContext))
            task.title = "Bookkeeping after the requested export"
            try container.mainContext.save() // invalidates the pending read
            return (root, workspace.id, observed)
        }
        let (root, workspaceID, observed) = try enqueueAndCloseOwner()
        defer { try? FileManager.default.removeItem(at: root) }
        // No actor hop yet: even a queued, not-yet-started read must release it.
        #expect(observed.value == nil)
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspaceID)
        #expect(observed.value == nil)
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path)))
        // Draining an orphaned request must skip its now-detached models.
        let cleanup = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: cleanup.mainContext)
    }

    @Test("A queued read skips a backing store removed before it starts")
    func removedBackingStoreIsNotFaulted() async throws {
        let (root, container, workspace, _) = try fixture()
        let workspaceID = workspace.id
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: workspaceID.uuidString)
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        try FileManager.default.removeItem(at: root)
        let written = await WorkspaceSavedAutoExport().export(container: container,
            workspaceID: workspaceID, url: url, ticket: ticket)
        #expect(!written)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("A prepared snapshot can finish writing after its store owner closes")
    func preparedSnapshotReleasesItsOwner() async throws {
        func prepareAndCloseOwner() async throws -> (URL, UUID, WeakContainer, WorkspaceSavedAutoExport.Prepared, WorkspaceAutoExportGate.Ticket) {
            let (root, container, workspace, _) = try fixture()
            container.mainContext.autosaveEnabled = true
            let id = workspace.id
            let observed = WeakContainer(container)
            let ticket = WorkspaceAutoExportGate.shared.beginExport(for: id.uuidString)
            let url = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
            let prepared = try #require(await WorkspaceSavedAutoExport().prepareForExport(
                source: WorkspaceSavedExportSource(container), workspaceID: id, url: url, ticket: ticket))
            return (root, id, observed, prepared, ticket)
        }
        let (root, id, observed, prepared, ticket) = try await prepareAndCloseOwner()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(observed.value == nil)
        // The writer needs only values: no live container/context is retained.
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        #expect(await WorkspaceAutoExportWriter.shared.write(prepared.config, to: url,
            workspaceID: id.uuidString, ticket: ticket))
        let mirror = try WorkspaceConfigManager.loadConfig(from: url)
        #expect(mirror.tasks?.first?.title == "First")
        #expect(observed.value == nil)
    }
}

private extension JSONDecoder {
    static var workspaceMirror: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
