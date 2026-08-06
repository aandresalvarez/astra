import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Covers the durability window opened by moving the workspace mirror export
/// off the task-open path and behind a 600 ms debounce. The mirror is what
/// workspace import and recovery read back, so anything still pending when the
/// process dies is silently reverted on the next import.
@MainActor
@Suite("Workspace export termination flush", .serialized)
struct WorkspaceExportTerminationFlushTests {
    @Test("Quitting inside the debounce window still writes the workspace mirror")
    func terminationFlushWritesTheDebouncedMirror() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Termination", primaryPath: root.path)
        context.insert(workspace)
        try context.save()

        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        // A debounce long enough that only an explicit flush can beat it stands
        // in for "the user pressed Command-Q 100 ms after opening a task".
        WorkspacePersistenceCoordinator.scheduleAutoExport(
            workspace: workspace,
            modelContext: context,
            delayNanoseconds: 600_000_000_000
        )
        #expect(!FileManager.default.fileExists(atPath: configURL.path))

        let delegate = ASTRAAppDelegate()
        delegate.modelContainer = container
        delegate.prepareForImmediateTermination()

        // Synchronous, not "eventually": the process is about to exit, so a
        // detached write task would never be scheduled.
        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("Termination drains every workspace that still has a pending export")
    func terminationFlushDrainsAllPendingWorkspaces() throws {
        let firstRoot = try makeWorkspaceRoot()
        let secondRoot = try makeWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let container = try makeContainer()
        let context = container.mainContext
        let first = Workspace(name: "First", primaryPath: firstRoot.path)
        let second = Workspace(name: "Second", primaryPath: secondRoot.path)
        context.insert(first)
        context.insert(second)
        try context.save()

        WorkspacePersistenceCoordinator.scheduleAutoExport(
            workspace: first,
            modelContext: context,
            delayNanoseconds: 600_000_000_000
        )
        WorkspacePersistenceCoordinator.scheduleAutoExport(
            workspace: second,
            modelContext: context,
            delayNanoseconds: 600_000_000_000
        )
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount >= 2)

        let flushed = WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context)
        #expect(flushed >= 2)

        let firstConfig = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: firstRoot.path))
        let secondConfig = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: secondRoot.path))
        #expect(FileManager.default.fileExists(atPath: firstConfig.path))
        #expect(FileManager.default.fileExists(atPath: secondConfig.path))
    }

    @Test("Termination without a pending export writes nothing")
    func terminationFlushIsANoOpWhenNothingIsPending() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Idle", primaryPath: root.path)
        context.insert(workspace)
        try context.save()

        // Bounded on purpose: quit must not fan out an export across every
        // workspace in the store, only the ones mid-debounce.
        WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context)
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("Both terminating paths drain the export queue before the app quits")
    func everyTerminatingPathDrainsTheExportQueue() throws {
        let root = try TestRepositoryRoot.resolve()
        let app = try String(
            contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"),
            encoding: .utf8
        )
        let start = try #require(app.range(of: "func applicationShouldTerminate("))
        let end = try #require(app.range(of: "func prepareForImmediateTermination("))
        let body = app[start.upperBound..<end.lowerBound]

        // The immediate path and the post-shutdown reply both let the process
        // die, so both must drain first.
        #expect(body.components(separatedBy: "prepareForImmediateTermination").count - 1 == 2)

        let firstDrain = try #require(body.range(of: "prepareForImmediateTermination"))
        let terminateNow = try #require(body.range(of: "return .terminateNow"))
        #expect(firstDrain.lowerBound < terminateNow.lowerBound)

        let lastDrain = try #require(body.range(of: "prepareForImmediateTermination", options: .backwards))
        let reply = try #require(body.range(of: "sender.reply("))
        #expect(lastDrain.lowerBound < reply.lowerBound)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-terminate-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
