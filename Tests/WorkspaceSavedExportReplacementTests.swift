import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

private actor ProjectionWriteLatch {
    enum Failure: Error { case projectionDidNotReachPause }
    private var entered = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard entered else { throw Failure.projectionDidNotReachPause }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
@Suite("Committed recovery projection replacement", .serialized)
struct WorkspaceSavedExportReplacementTests {
    private func fixture() throws -> (URL, ModelContainer, Workspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-replacement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"))])
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Prior committed", primaryPath: root.path)
        context.insert(workspace); try context.save()
        return (root, container, workspace)
    }

    @Test("A failing replacement keeps the prior real prepared write alive", arguments: [false, true], ["write", "projection"])
    func failingReplacement(existingMirror: Bool, stage: String) async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let url = try #require(WorkspaceConfigManager.autoExportTarget(for: root.path).url)
        if existingMirror {
            workspace.name = "Older mirror"
            #expect(WorkspaceConfigManager.exportToFileResult(workspace: workspace, modelContext: context, url: url).didExport)
            workspace.name = "Prior committed"
            try context.save()
        }
        let latch = ProjectionWriteLatch()
        defer { Task { await latch.release() } }
        let pause: @Sendable () async -> Void = { await latch.pause() }
        let writer = WorkspaceAutoExportWriter(beforeWrite: stage == "write" ? pause : nil)
        let reader = WorkspaceSavedAutoExport(beforeProjection: stage == "projection" ? pause : nil)
        let prior = try #require(WorkspacePersistenceCoordinator.enqueueSavedAutoExport(
            workspace: workspace, modelContext: context, writer: writer, reader: reader))
        try await latch.waitForArrival() // A real copied store or its prepared value is paused.
        // Make the replacement fail in the actual protected snapshot service.
        let lock = root.appendingPathComponent(".astra-mirror-cleanup.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        workspace.name = "New committed"
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        #expect(!prior.isCancelled, "A committed value must survive replacement preparation")
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        await latch.release()
        await prior.value
        #expect(try WorkspaceConfigManager.loadConfig(from: url).name == "Prior committed")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 1,
            "Finishing the fallback must not erase the newer failed obligation")
        try FileManager.default.removeItem(at: lock)
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1)
        #expect(try WorkspaceConfigManager.loadConfig(from: url).name == "New committed")
    }

    @Test("A successful replacement supersedes a blocked prior copy without losing newer work", arguments: ["write", "projection"])
    func successfulReplacement(stage: String) async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let latch = ProjectionWriteLatch()
        defer { Task { await latch.release() } }
        let pause: @Sendable () async -> Void = { await latch.pause() }
        let writer = WorkspaceAutoExportWriter(beforeWrite: stage == "write" ? pause : nil)
        let reader = WorkspaceSavedAutoExport(beforeProjection: stage == "projection" ? pause : nil)
        let prior = try #require(WorkspacePersistenceCoordinator.enqueueSavedAutoExport(
            workspace: workspace, modelContext: context, writer: writer, reader: reader))
        try await latch.waitForArrival()
        workspace.name = "New committed"
        #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        let latest = try Data(contentsOf: url)
        await latch.release(); await prior.value
        #expect(try Data(contentsOf: url) == latest)
        #expect(try WorkspaceConfigManager.loadConfig(from: url).name == "New committed")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
    }

    @Test("Prepared writes preserve committed data but reject moved or deleted destinations",
          arguments: ["bookkeeping", "move", "delete", "termination"], ["write", "projection"])
    func preparedValueBoundary(change: String, stage: String) async throws {
        let (root, container, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let latch = ProjectionWriteLatch()
        defer { Task { await latch.release() } }
        let pause: @Sendable () async -> Void = { await latch.pause() }
        let writer = WorkspaceAutoExportWriter(beforeWrite: stage == "write" ? pause : nil)
        let reader = WorkspaceSavedAutoExport(beforeProjection: stage == "projection" ? pause : nil)
        let prior = try #require(WorkspacePersistenceCoordinator.enqueueSavedAutoExport(
            workspace: workspace, modelContext: context, writer: writer, reader: reader))
        try await latch.waitForArrival()
        switch change {
        case "move":
            let moved = root.appendingPathComponent("Moved")
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            workspace.primaryPath = moved.path
        case "delete": SwiftDataDeletionPreparation.prepare(workspace); context.delete(workspace)
        default: workspace.name = "Later committed"
        }
        try context.save()
        if change == "termination" {
            #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1)
        }
        await latch.release(); await prior.value
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        if change == "move" || change == "delete" {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else {
            #expect(try WorkspaceConfigManager.loadConfig(from: url).name ==
                (change == "termination" ? "Later committed" : "Prior committed"))
        }
    }
}
