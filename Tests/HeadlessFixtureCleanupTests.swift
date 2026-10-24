import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence

@Suite("Headless fixture store lifetime", .serialized)
@MainActor
struct HeadlessFixtureCleanupTests {
    @Test("Cleanup waits for an active synchronous snapshot reader before deleting its store")
    func cleanupJoinsActiveRead() async throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        var cleanupRequested = false
        defer { if !cleanupRequested { harness.cleanup() } }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Fixture", model: "claude-sonnet-4-6")
        let workspaceID = try #require(task.workspace).id
        harness.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: "Read stays valid"))
        try harness.context.save()
        let container = harness.container
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let read = Task {
            defer { entered.continuation.finish() }
            return try await WorkspaceSavedAutoExport.shared.holdFixtureSnapshot(container: container,
                workspaceID: workspaceID, entered: { entered.continuation.yield() }, release: release)
        }
        for await _ in entered.stream { break }
        let cleanupStarted = AsyncStream<Void>.makeStream()
        let cleanup = TestWorkspaceStoreCleanup.schedule(context: harness.context, roots: [harness.rootURL],
            onStart: { cleanupStarted.continuation.yield() })
        cleanupRequested = true
        for await _ in cleanupStarted.stream { break }
        #expect(FileManager.default.fileExists(atPath: harness.rootURL.path))
        release.signal()
        #expect(try await read.value == TaskEventTypes.System.info.rawValue)
        await cleanup.value
        #expect(!FileManager.default.fileExists(atPath: harness.rootURL.path))
    }

    @Test("Cleanup retires an older sealed export after a newer export fails publication")
    func cleanupRetiresSupersededReader() async throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Fixture", model: "claude-sonnet-4-6")
        let workspace = try #require(task.workspace)
        try harness.context.save()
        let gate = FixtureProjectionGate()
        let reader = WorkspaceSavedAutoExport(beforeProjection: { await gate.pauseFirst() })
        let old = try #require(WorkspacePersistenceCoordinator.enqueueSavedAutoExport(
            workspace: workspace, modelContext: harness.context, reader: reader))
        await gate.waitUntilPaused()
        let oldTicket = WorkspaceAutoExportGate.shared.readTicket(for: workspace.id.uuidString)
        let destination = try #require(WorkspaceConfigManager.autoExportTarget(for: workspace.primaryPath).url)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let newer = try #require(WorkspacePersistenceCoordinator.enqueueSavedAutoExport(
            workspace: workspace, modelContext: harness.context, reader: reader))
        await newer.value
        #expect(WorkspaceAutoExportGate.shared.isSealedCurrent(oldTicket))
        #expect(FileManager.default.fileExists(atPath: harness.rootURL.path))
        // The older sealed read still owns a snapshot under this root. It must
        // never touch SwiftData after cleanup retires its epoch and removes it.
        await harness.cleanup(reader: reader).value
        #expect(!WorkspaceAutoExportGate.shared.isSealedCurrent(oldTicket))
        #expect(!FileManager.default.fileExists(atPath: harness.rootURL.path))
        await gate.release()
        await old.value
    }
}

private actor FixtureProjectionGate {
    private var first = true
    private var paused = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard first else { return }
        first = false
        paused = true
        for waiter in entered { waiter.resume() }
        entered.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func release() { continuation?.resume(); continuation = nil }
}

private extension WorkspaceSavedAutoExport {
    func holdFixtureSnapshot(container: ModelContainer, workspaceID: UUID,
                             entered: @Sendable () -> Void, release: DispatchSemaphore) throws -> String? {
        try WorkspaceSavedExportSnapshot.read(container: container, workspaceID: workspaceID.uuidString) { snapshot in
            let context = ModelContext(snapshot)
            context.autosaveEnabled = false
            let event = try context.fetch(FetchDescriptor<TaskEvent>()).first
            entered()
            guard release.wait(timeout: .now() + 10) == .success else { return nil }
            return event?.type
        }
    }
}
