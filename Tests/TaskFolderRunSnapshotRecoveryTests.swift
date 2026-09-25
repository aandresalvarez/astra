import CryptoKit
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Task folder run snapshot recovery")
@MainActor
struct TaskFolderRunSnapshotRecoveryTests {
    @Test("A run's baseline stays until the changes it compared are saved")
    func baselineLivesUntilTheRunIsSaved() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try write("v1", to: fixture.folder, "plan.md")

        let before = await TaskFolderRunSnapshot.capture(for: fixture.task)
        await TaskFolderRunSnapshot.persistBaseline(before, task: fixture.task, run: fixture.run)
        #expect(FileManager.default.fileExists(atPath: fixture.baselineURL.path))
        try write("rows", to: fixture.folder, "report.csv")

        let outcome = await TaskFolderRunSnapshot.recordChanges(
            since: before,
            task: fixture.task,
            run: fixture.run,
            runStartedAt: fixture.run.startedAt,
            executionPath: fixture.workspace.path
        )
        #expect(outcome.observed)
        // Compared but unsaved: a crash now would lose the changes, so the
        // baseline is what recovery would replay.
        await TaskFolderRunSnapshot.settleBaseline(outcome, task: fixture.task, run: fixture.run)
        #expect(FileManager.default.fileExists(atPath: fixture.baselineURL.path))

        try fixture.container.mainContext.save()
        await TaskFolderRunSnapshot.settleBaseline(outcome, task: fixture.task, run: fixture.run)
        #expect(!FileManager.default.fileExists(atPath: fixture.baselineURL.path))
    }

    @Test("A run interrupted by a restart keeps what it created, edited, and removed")
    func interruptedRunIsRecoveredAtLaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try write("v1", to: fixture.folder, "plan.md")
        try write("old", to: fixture.folder, "stale.md")
        let before = await TaskFolderRunSnapshot.capture(for: fixture.task)
        await TaskFolderRunSnapshot.persistBaseline(before, task: fixture.task, run: fixture.run)

        // The provider changes the folder, then ASTRA dies before comparing.
        try "version two".write(to: fixture.folder.appendingPathComponent("plan.md"), atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("stale.md"))
        try write("rows", to: fixture.folder, "report.csv")

        TaskRunLifecycleService.recoverOrphanedRunningRuns(
            modelContext: fixture.container.mainContext,
            autoExportWorkspaces: false
        )
        await TaskFolderRunSnapshot.recoverPersistedBaselines(
            modelContext: fixture.container.mainContext,
            autoExportWorkspaces: false
        )

        #expect(fixture.run.status == .cancelled)
        let kinds = Dictionary(uniqueKeysWithValues: fixture.run.allFileChanges.map {
            (URL(fileURLWithPath: $0.path).lastPathComponent, $0.kind)
        })
        #expect(kinds == ["plan.md": .modified, "report.csv": .discovered, "stale.md": .removed])
        #expect(!FileManager.default.fileExists(atPath: fixture.baselineURL.path))
    }

    @Test("A run a quit cancelled before its worker compared is recovered at the next launch")
    func runCancelledBeforeItsComparisonIsRecovered() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let before = await TaskFolderRunSnapshot.capture(for: fixture.task)
        await TaskFolderRunSnapshot.persistBaseline(before, task: fixture.task, run: fixture.run)
        try write("rows", to: fixture.folder, "report.csv")
        // Quitting cancels the run and saves that, then the app exits before
        // the worker gets to compare: the next launch finds it already done.
        TaskRunLifecycleService.cancelTask(
            fixture.task,
            modelContext: fixture.container.mainContext,
            source: .queueStopped
        )
        try fixture.container.mainContext.save()

        await TaskFolderRunSnapshot.recoverPersistedBaselines(
            modelContext: fixture.container.mainContext,
            autoExportWorkspaces: false
        )

        #expect(fixture.run.allFileChanges.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["report.csv"])
        #expect(!FileManager.default.fileExists(atPath: fixture.baselineURL.path))
    }

    @Test("A baseline whose run no longer exists is removed at launch")
    func baselineOfADeletedRunIsRemoved() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let before = try #require(await TaskFolderRunSnapshot.capture(for: fixture.task))
        let deletedRunID = UUID()
        #expect(TaskFolderRunSnapshot.writeBaseline(before, runID: deletedRunID))
        let orphan = TaskFolderRunSnapshot.baselineURL(taskFolder: fixture.folder.path, runID: deletedRunID)

        await TaskFolderRunSnapshot.recoverPersistedBaselines(
            modelContext: fixture.container.mainContext,
            autoExportWorkspaces: false
        )

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Writing a baseline removes the ones earlier runs of the task left behind")
    func persistingABaselineRemovesStaleOnes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let before = await TaskFolderRunSnapshot.capture(for: fixture.task)
        let staleRunID = UUID()
        let staleURL = TaskFolderRunSnapshot.baselineURL(taskFolder: fixture.folder.path, runID: staleRunID)
        #expect(TaskFolderRunSnapshot.writeBaseline(try #require(before), runID: staleRunID))

        await TaskFolderRunSnapshot.persistBaseline(before, task: fixture.task, run: fixture.run)

        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.baselineURL.path))
    }

    @Test("An unreadable baseline is skipped and removed, not compared")
    func unreadableBaselineIsIgnoredAndRemoved() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try write("rows", to: fixture.folder, "report.csv")
        try FileManager.default.createDirectory(
            at: fixture.baselineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{not json".write(to: fixture.baselineURL, atomically: true, encoding: .utf8)
        fixture.run.status = .cancelled

        await TaskFolderRunSnapshot.recoverPersistedBaselines(
            modelContext: fixture.container.mainContext,
            autoExportWorkspaces: false
        )

        #expect(fixture.run.allFileChanges.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.baselineURL.path))
    }

    @Test("A persisted baseline reads back exactly, fingerprints and times included")
    func persistedBaselineRoundTrips() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try write("v1", to: fixture.folder, "plan.md")
        let before = try #require(await TaskFolderRunSnapshot.capture(for: fixture.task))
        #expect(before.entries["plan.md"]?.contentFingerprint != nil)

        #expect(TaskFolderRunSnapshot.writeBaseline(before, runID: fixture.run.id))
        let load = TaskFolderRunSnapshot.loadBaseline(at: fixture.baselineURL, runID: fixture.run.id)

        guard case .loaded(let loaded) = load else {
            Issue.record("Expected the baseline to load")
            return
        }
        #expect(loaded.entries == before.entries)
        #expect(loaded.root == before.root)
        // A baseline written for another run is not this run's.
        guard case .unreadable = TaskFolderRunSnapshot.loadBaseline(at: fixture.baselineURL, runID: UUID()) else {
            Issue.record("Expected a mismatched run id to be unreadable")
            return
        }
    }

    @Test("The content fingerprint is the SHA-256 prefix, the same in every launch")
    func fingerprintIsStableAcrossLaunches() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("abc.txt")
        try "abc".write(to: url, atomically: true, encoding: .utf8)

        let read = TaskFolderRunSnapshot.contentFingerprint(
            of: url,
            maxBytes: 16,
            intent: .astraManagedStorage(root: folder)
        )

        // SHA-256("abc") begins ba7816bf 8f01cfea.
        #expect(read.fingerprint == 0xBA78_16BF_8F01_CFEA)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let container: ModelContainer
        let workspace: URL
        let folder: URL
        let task: AgentTask
        let run: TaskRun

        var baselineURL: URL {
            TaskFolderRunSnapshot.baselineURL(taskFolder: folder.path, runID: run.id)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    private func makeFixture() throws -> Fixture {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-snapshot-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Recovery", primaryPath: workspaceURL.path)
        let task = AgentTask(title: "Recover", goal: "Change files", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()
        let folder = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Fixture(container: container, workspace: workspaceURL, folder: folder, task: task, run: run)
    }

    private func write(_ text: String, to folder: URL, _ relativePath: String) throws {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
