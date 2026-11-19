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

    private var touched: [String] = []

    func noteRead() { lock.withLock { onMain.append(Thread.isMainThread) } }
    func note(_ touch: String) { lock.withLock { touched.append(touch) } }
    var touches: [String] { lock.withLock { touched } }
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
        let paths = StartupCleanupPathPreflight.Paths(
            folders: ["/blocked"], identified: ["/pinned.json"], read: [["/mirror.json"]]
        )
        let preflight = Task {
            await StartupCleanupPathPreflight.run(paths, walk: { _ in
                probe.beginWalk()
                _ = gate.wait(timeout: .now() + 10)
                probe.endWalk()
            }, identify: { _ in probe.noteRead() }, read: { _ in probe.noteRead(); return false })
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
        #expect(probe.calls == [false, false, false])
    }

    @Test("Nothing to read returns without touching the queue")
    func emptyPathsReturnAtOnce() async {
        let probe = PreflightProbe()
        await StartupCleanupPathPreflight.run(.init(), walk: { _ in probe.beginWalk() },
            identify: { _ in probe.noteRead() }, read: { _ in probe.noteRead(); return false })
        #expect(probe.calls.isEmpty)
    }

    @Test("A deletion's mirror is identified and never opened; each mirror list is read only up to the first file that is there")
    func deletionMirrorsStayMetadataOnlyAndLegacyIsAFallback() async {
        let probe = PreflightProbe()
        let paths = StartupCleanupPathPreflight.Paths(
            folders: [], identified: ["/deleted/.astra-workspace.json"],
            read: [["/present/current.json", "/present/legacy.json"], ["/absent/current.json", "/absent/legacy.json"]]
        )
        await StartupCleanupPathPreflight.run(paths, walk: { _ in },
            identify: { probe.note("identify " + $0) },
            read: { path in
                probe.note("read " + path)
                return path.hasPrefix("/absent/current")
            })
        #expect(probe.touches == [
            "identify /deleted/.astra-workspace.json",
            "read /present/current.json",
            "read /absent/current.json", "read /absent/legacy.json"
        ])
    }

    @Test("The default reader moves on to the next mirror only for a file confirmed missing")
    func defaultReaderReportsOnlyAMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let present = root.appendingPathComponent("mirror.json")
        try Data("{}".utf8).write(to: present)
        #expect(!StartupCleanupPathPreflight.isMissingAfterReading(present.path))
        #expect(StartupCleanupPathPreflight.isMissingAfterReading(root.appendingPathComponent("gone.json").path))
        // There but not readable as a file: the reader stops, it doesn't fall back.
        #expect(!StartupCleanupPathPreflight.isMissingAfterReading(root.path))
    }

    @Test("An unsaved folder edit doesn't hide the stored workspace location from the preflight")
    @MainActor
    func savedAndCurrentWorkspacePathsAreBothCovered() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = root.appendingPathComponent("Saved").path
        let edited = root.appendingPathComponent("Edited").path
        let workspace = Workspace(name: "Moved", primaryPath: saved)
        context.insert(workspace)
        try context.save()
        workspace.primaryPath = edited

        let paths = StartupCleanupPathPreflight.paths(
            modelContext: context, store: WorkspaceDeletionCleanupStore(directory: root.appendingPathComponent("DeletionCleanup")),
            extraMirrors: []
        )

        for location in [saved, edited] {
            let mirrors = [WorkspaceFileLayout.workspaceConfigFile(for: location),
                           WorkspaceFileLayout.legacyWorkspaceConfigFile(for: location)]
            #expect(paths.read.contains(mirrors), "\(location)")
            #expect(paths.folders.contains((mirrors[0] as NSString).deletingLastPathComponent))
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Workspace>()).first?.primaryPath == saved)
    }

    @Test("The preflight covers what the passes touch: pending deletions' mirrors and folders, moved mirrors, and stored workspaces' mirrors")
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
        let read = Array(paths.read.joined())
        #expect(!deleted.mirrorFiles.isEmpty)
        // A deletion's own mirrors are identified, never opened.
        for file in deleted.mirrorFiles {
            #expect(paths.identified.contains(file))
            #expect(!read.contains(file))
        }
        // The current mirror before the legacy one, as the reader tries them.
        #expect(paths.read.contains(liveMirrors))
        #expect(paths.identified.contains(moved))
        #expect(paths.read.contains([moved]) && paths.read.contains([loaded]))
        for file in deleted.mirrorFiles + liveMirrors {
            #expect(paths.folders.contains((file as NSString).deletingLastPathComponent))
        }
        #expect(Set(read).count == read.count)
        #expect(Set(paths.identified).count == paths.identified.count)
        #expect(Set(paths.folders).count == paths.folders.count)
        #expect(!read.contains("") && !paths.identified.contains("") && !paths.folders.contains(""))
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
