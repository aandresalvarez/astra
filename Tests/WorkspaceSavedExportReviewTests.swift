import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@MainActor
@Suite("Saved export review regressions", .serialized)
struct WorkspaceSavedExportReviewTests {
    private func fixture() throws -> (URL, ModelContainer, Workspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-export-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("fixture.store"))])
        container.mainContext.autosaveEnabled = false
        let workspace = Workspace(name: "Last saved", primaryPath: root.path)
        container.mainContext.insert(workspace)
        container.mainContext.insert(AgentTask(title: "Saved task", goal: "Synthetic", workspace: workspace))
        try container.mainContext.save()
        return (root, container, workspace)
    }

    @Test("A real failing save preserves the pending mirror of the last durable state",
          arguments: ["automatic", "throwing", "bookkeeping", "throwing-bookkeeping", "raw"])
    func failedSaveKeepsLastDurableProjection(mode: String) async throws {
        let (root, seed, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let readOnly = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("fixture.store"), allowsSave: false)])
        let context = readOnly.mainContext
        context.autosaveEnabled = false
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let id = original.id
        let workspace = try #require(context.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
        // A clean context has nothing to commit and may enqueue its saved rows.
        try #require(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.readTicket(for: id.uuidString)
        workspace.name = "Unsaved failing change"
        switch mode {
        case "automatic":
            #expect(!WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        case "bookkeeping":
            #expect(!WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context))
        default:
            var failed = false
            do {
                if mode == "throwing" {
                    try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: workspace, modelContext: context)
                } else if mode == "throwing-bookkeeping" {
                    try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: workspace, modelContext: context)
                } else { try context.save() }
            } catch { failed = true }
            #expect(failed)
        }
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket), "A failed save did not change durable rows")
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: id)
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        let data = try #require(try? Data(contentsOf: url), "The last successful state still needs its recovery mirror")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let mirror = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: data)
        #expect(mirror.name == "Last saved")
        #expect(mirror.tasks?.first?.title == "Saved task")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
        withExtendedLifetime(seed) {}
    }

    @Test("A successful explicit export retires its superseded pending projection")
    func explicitExportRetiresPendingWork() async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        workspace.name = "Explicit snapshot"
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: context)
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: url.path),
               WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let beforeDrain = try Data(contentsOf: url)
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 0)
        #expect(try Data(contentsOf: url) == beforeDrain, "Quit must not repeat a completed whole-workspace export")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: beforeDrain).name == "Explicit snapshot")
    }

    @Test("A failed explicit write remains owed for a later explicit drain")
    func failedExplicitWriteRemainsPending() async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: workspace.id.uuidString)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(await WorkspaceAutoExportWriter.shared.write(config, to: url,
            workspaceID: workspace.id.uuidString, ticket: ticket) == false)
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 1)
        try FileManager.default.removeItem(at: url)
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An older explicit completion preserves a later saved or debounced request", arguments: [false, true])
    func olderCompletionKeepsNewerWork(saved: Bool) async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        let explicit = WorkspaceAutoExportGate.shared.beginExport(for: workspace.id.uuidString)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        workspace.name = "Later request"
        if saved {
            #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        } else {
            WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: context,
                delayNanoseconds: 600_000_000_000)
        }
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        let written = await WorkspaceAutoExportWriter.shared.write(config, to: url,
            workspaceID: workspace.id.uuidString, ticket: explicit)
        if saved {
            // The older value may publish first, or the newer preparation may
            // already have superseded it. Either order must finish the latest
            // obligation; the blocked-writer regression fixes that order.
            await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        } else {
            #expect(written)
            #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 1)
            #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let mirror = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: Data(contentsOf: url))
        #expect(mirror.name == "Later request")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
    }
    @Test("A failed explicit preparation preserves the previous queued snapshot", arguments: [false, true])
    func failedPreparationKeepsQueuedSnapshot(registryFailure: Bool) async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let url = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: workspace.id.uuidString)
        if registryFailure {
            let registry = try #require(WorkspaceMirrorRegistry(for: context))
            try Data("Blocks the registry directory".utf8).write(to: registry.directory)
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: context)
        } else {
            // A store-fetch error has the same nil snapshot result. Keep the
            // writer queued deterministically until the failed attempt returns.
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: context, makeSnapshot: { nil })
        }
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket))
        #expect(await WorkspaceAutoExportWriter.shared.write(config, to: url,
            workspaceID: workspace.id.uuidString, ticket: ticket))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self,
            from: Data(contentsOf: url)).name == "Last saved")
    }

    @Test("An explicit export attempt after deletion retires a queued snapshot")
    func deletedPreparationRetiresQueuedSnapshot() async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        let url = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: workspace.id.uuidString)
        SwiftDataDeletionPreparation.prepare(workspace)
        context.delete(workspace)
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: context)
        #expect(!WorkspaceAutoExportGate.shared.isCurrent(ticket))
        #expect(await WorkspaceAutoExportWriter.shared.write(config, to: url,
            workspaceID: workspace.id.uuidString, ticket: ticket) == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

}
