import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence
import ASTRACore

// A new build's first read inside Documents raises a macOS privacy prompt that
// blocks the read until it is answered. The startup cleanup passes read on the
// main actor, so the preflight must take that wait off it first.

private final class PreflightProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []
    private var walking = false
    private var walked = false

    func noteRead() { lock.withLock { onMain.append(Thread.isMainThread) } }
    func beginWalk() { lock.withLock { onMain.append(Thread.isMainThread); walking = true } }
    func endWalk() { lock.withLock { walked = true } }
    var isWalking: Bool { lock.withLock { walking } }
    var hasWalked: Bool { lock.withLock { walked } }
    var calls: [Bool] { lock.withLock { onMain } }
}

@Suite("Startup cleanup path preflight")
struct StartupCleanupPathPreflightTests {
    @Test("A walk that blocks holds the preflight's queue, never the main actor")
    func blockedWalkLeavesMainActorFree() async {
        let gate = DispatchSemaphore(value: 0)
        let probe = PreflightProbe()
        let paths = StartupCleanupPathPreflight.Paths(folders: ["/blocked"], files: ["/mirror.json"])
        let preflight = Task {
            await StartupCleanupPathPreflight.run(paths, walk: { _ in
                probe.beginWalk()
                _ = gate.wait(timeout: .now() + 10)
                probe.endWalk()
            }, read: { _ in probe.noteRead() })
        }
        for _ in 0..<1_000 where !probe.isWalking { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(probe.isWalking)
        // While the walk is still blocked, the main actor runs other work.
        let mainRan = await MainActor.run { true }
        #expect(mainRan)
        #expect(!probe.hasWalked)
        gate.signal()
        await preflight.value
        #expect(probe.hasWalked)
        #expect(probe.calls == [false, false])
    }

    @Test("Nothing to read returns without touching the queue")
    func emptyPathsReturnAtOnce() async {
        let probe = PreflightProbe()
        await StartupCleanupPathPreflight.run(.init(), walk: { _ in probe.beginWalk() }, read: { _ in probe.noteRead() })
        #expect(probe.calls.isEmpty)
    }

    @Test("The preflight covers what the passes read: pending deletions' mirrors and folders, moved mirrors, and stored workspaces' mirrors")
    @MainActor
    func pathsCoverWhatThePassesRead() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = Workspace(name: "Live", primaryPath: root.appendingPathComponent("Live").path)
        context.insert(live)
        context.insert(Workspace(name: "Pathless", primaryPath: ""))
        try context.save()
        let store = WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("DeletionCleanup"))
        let deleted = WorkspaceDeletionCleanupRecord(
            workspaceID: UUID(), primaryPath: root.appendingPathComponent("Deleted").path, connectors: [], skills: []
        )
        try store.write(deleted)
        let moved = root.appendingPathComponent("Moved/.astra-workspace.json").path
        let loaded = root.appendingPathComponent("Loaded/.astra-workspace.json").path

        let paths = StartupCleanupPathPreflight.paths(
            modelContext: context, store: store, movedMirrors: [moved, moved], extraMirrors: [loaded]
        )

        let liveMirrors = [WorkspaceFileLayout.workspaceConfigFile(for: live.primaryPath),
                           WorkspaceFileLayout.legacyWorkspaceConfigFile(for: live.primaryPath)]
        #expect(!deleted.mirrorFiles.isEmpty)
        for file in deleted.mirrorFiles + liveMirrors + [moved, loaded] { #expect(paths.files.contains(file)) }
        for file in deleted.mirrorFiles + liveMirrors {
            #expect(paths.folders.contains((file as NSString).deletingLastPathComponent))
        }
        #expect(Set(paths.files).count == paths.files.count)
        #expect(Set(paths.folders).count == paths.folders.count)
        #expect(!paths.files.contains("") && !paths.folders.contains(""))
    }

    @Test("Startup runs the preflight behind the trust gate, then gates again before the main-actor passes")
    func startupRunsPreflightBeforeMainActorPasses() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8
        )
        let gateText = "guard !Task.isCancelled, WorkspaceRecoveryTrust.allowsCleanup else { return }"
        let task = try #require(app.range(of: "credentialCleanupAfterLaunch = Task { @MainActor in"))
        let gate = try #require(app.range(of: gateText, range: task.upperBound..<app.endIndex))
        let preflight = try #require(app.range(of: "await StartupCleanupPathPreflight.run(", range: task.upperBound..<app.endIndex))
        let deletions = try #require(app.range(of: "WorkspaceDeletionCleanupService.resumePending(", range: task.upperBound..<app.endIndex))
        let connectors = try #require(app.range(of: "ConnectorCredentialCleanup.resumePending(", range: task.upperBound..<app.endIndex))
        #expect(gate.upperBound <= preflight.lowerBound)
        #expect(preflight.upperBound < deletions.lowerBound && deletions.upperBound < connectors.lowerBound)
        #expect(app[preflight.upperBound..<deletions.lowerBound].contains(gateText))
    }
}
