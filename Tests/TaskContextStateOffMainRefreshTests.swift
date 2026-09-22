import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// `refreshLoadingOffMainActor` exists only to keep the task folder resolve and
/// the `current_state.json` read off the main actor. It must therefore leave
/// exactly the state `refresh` would, or task open would silently diverge from
/// the durable launch path that still calls `refresh`.
@Suite("Context state refresh off the main actor", .serialized)
@MainActor
struct TaskContextStateOffMainRefreshTests {
    @Test("The off-actor refresh writes the state the synchronous one would")
    func offActorRefreshMatchesSynchronousRefresh() async throws {
        let fixture = try makeFixture("equivalence")
        defer { fixture.cleanup() }
        let path = URL(fileURLWithPath: fixture.folder)
            .appendingPathComponent(TaskContextStateManager.jsonFileName)

        // Seed durable state the refresh has to carry forward, so the
        // comparison can tell "read the file and reconciled it" apart from
        // "rebuilt from the model". Without this both paths would agree
        // trivially on a fresh task.
        var seeded = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        seeded.objectiveAssessment = TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: "Preserve the imported pivot",
            assessedAtTurn: 7,
            inputHash: "input-hash"
        )
        seeded.turns = [TaskContextState.Turn(
            turn: 1,
            ask: "Seeded ask",
            summary: "Seeded summary",
            filesChanged: ["seeded.swift"],
            blockers: [],
            runStatus: "completed"
        )]
        #expect(TaskContextStateManager.saveState(seeded, taskFolder: fixture.folder).didSave)
        let seededBytes = try Data(contentsOf: path)

        // Same task down both paths, so any difference is the code's, not the
        // fixture's: two tasks would differ by id in `objective.sourcePointers`
        // whatever the refresh did.
        TaskContextStateManager.refresh(task: fixture.task)
        let expected = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))

        try seededBytes.write(to: path)
        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)
        var actual = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))

        // `updatedAt` is a wall clock; everything else must match exactly.
        actual.updatedAt = expected.updatedAt
        #expect(actual == expected)
        #expect(actual.objectiveAssessment?.currentObjective == "Preserve the imported pivot")
        // Turns live only in the file, so this is the part of `existing` that
        // nothing else can reconstruct.
        #expect(actual.turns.map(\.ask) == ["Seeded ask"])
    }

    @Test("The off-actor refresh creates the state file when none exists yet")
    func offActorRefreshCreatesMissingState() async throws {
        let fixture = try makeFixture("missing")
        defer { fixture.cleanup() }
        let path = URL(fileURLWithPath: fixture.folder)
            .appendingPathComponent(TaskContextStateManager.jsonFileName)
        try? FileManager.default.removeItem(at: path)
        #expect(FileManager.default.fileExists(atPath: path.path) == false)

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("A second off-actor refresh over unchanged state rewrites nothing")
    func repeatedOffActorRefreshIsANoOp() async throws {
        let fixture = try makeFixture("noop")
        defer { fixture.cleanup() }
        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)
        let path = URL(fileURLWithPath: fixture.folder)
            .appendingPathComponent(TaskContextStateManager.jsonFileName)
        let firstModified = try modificationDate(of: path)

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        // The no-op guard in `applyRefresh` is what keeps task open off the
        // encode-and-write path; losing it would not fail any assertion above.
        #expect(try modificationDate(of: path) == firstModified)
    }

    @Test("A write that lands during the off-actor read is not overwritten")
    func concurrentWriteIsNotClobbered() async throws {
        let fixture = try makeFixture("clobber")
        defer { fixture.cleanup() }
        // Inserted and saved so the refresh's derived fields actually move:
        // a refresh that finds nothing to change returns before saving, and
        // then there is no overwrite to catch.
        let run = TaskRun(task: fixture.task)
        run.status = .completed
        run.setOutput("answer")
        run.completedAt = Date()
        fixture.container.mainContext.insert(run)
        try fixture.container.mainContext.save()

        // Land a durable write in the window between the off-actor read and
        // the apply — the interleaving that made this revalidation necessary.
        TaskContextStateManager.interleaveForTesting = {
            TaskContextStateManager.recordTurn(
                task: fixture.task,
                run: run,
                message: "turn recorded mid-refresh"
            )
        }
        defer { TaskContextStateManager.interleaveForTesting = nil }

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        // Without the stamp check the refresh derives from the snapshot it read
        // before that write and saves over it, silently dropping the turn.
        let state = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(state.turns.contains { $0.ask == "turn recorded mid-refresh" })
    }

    @Test("A write landing inside the off-actor read is not overwritten")
    func writeDuringReadIsNotClobbered() async throws {
        let fixture = try makeFixture("straddle")
        defer { fixture.cleanup() }
        let run = TaskRun(task: fixture.task)
        run.status = .completed
        run.setOutput("answer")
        run.completedAt = Date()
        fixture.container.mainContext.insert(run)
        try fixture.container.mainContext.save()
        let folder = fixture.folder

        // Straddle the read itself, not the window after it: stamping only
        // after the read would describe this writer's file, so the check at the
        // apply would match and put the pre-write snapshot back over it.
        TaskContextStateManager.interleaveDuringLoadForTesting = {
            guard var state = TaskContextStateManager.load(taskFolder: folder) else { return }
            state.turns.append(TaskContextState.Turn(
                turn: 99,
                ask: "written during the read",
                summary: "",
                filesChanged: [],
                blockers: [],
                runStatus: "completed"
            ))
            _ = TaskContextStateManager.saveState(state, taskFolder: folder)
        }
        defer { TaskContextStateManager.interleaveDuringLoadForTesting = nil }

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.turns.contains { $0.ask == "written during the read" })
    }

    @Test("The off-actor load never quarantines; recovery stays on the actor")
    func detachedLoadDoesNotQuarantine() async throws {
        let fixture = try makeFixture("quarantine")
        defer { fixture.cleanup() }
        let folder = fixture.folder
        let path = URL(fileURLWithPath: folder)
            .appendingPathComponent(TaskContextStateManager.jsonFileName)
        try "{ not json".write(to: path, atomically: true, encoding: .utf8)

        // Sampled off the actor, immediately after the load: quarantining
        // *moves* the file, and doing that here races every writer — it can
        // observe the corruption, let `recordTurn` replace the file with good
        // state, then quarantine that new file and lose the turn.
        nonisolated(unsafe) var quarantinedDuringLoad = true
        TaskContextStateManager.interleaveDuringLoadForTesting = {
            quarantinedDuringLoad = !Self.corruptCopies(in: folder).isEmpty
        }
        defer { TaskContextStateManager.interleaveDuringLoadForTesting = nil }

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        #expect(quarantinedDuringLoad == false, "the detached half must not write")
        // The recovery itself still has to happen — just under the actor.
        #expect(!Self.corruptCopies(in: folder).isEmpty, "the corrupt file must still be quarantined")
    }

    @Test("A missing state file uses the precomputed inventory, not a rescan")
    func missingStateFileDoesNotRescanOnTheActor() async throws {
        let fixture = try makeFixture("missing-fast")
        defer { fixture.cleanup() }
        let path = URL(fileURLWithPath: fixture.folder)
            .appendingPathComponent(TaskContextStateManager.jsonFileName)
        try FileManager.default.removeItem(at: path)
        TaskContextStateManager.fallbackCountForTesting = 0

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        // A missing file is the ordinary case for a new or imported task and
        // needs no recovery, so it must not cost the main-actor rescan that
        // every unhealthy status does.
        #expect(TaskContextStateManager.fallbackCountForTesting == 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("A load invalidated once is retried off the actor, not rescanned on it")
    func invalidatedLoadRetriesOffActor() async throws {
        let fixture = try makeFixture("retry")
        defer { fixture.cleanup() }
        let folder = fixture.folder
        TaskContextStateManager.fallbackCountForTesting = 0
        TaskContextStateManager.revalidationRetryCountForTesting = 0

        // Replaces the state file on the first attempt only, so it is settled
        // by the second. Recovering from this by redoing the refresh under the
        // actor would spend exactly what moving the read off it saved.
        nonisolated(unsafe) var perturbed = false
        TaskContextStateManager.interleaveForTesting = {
            guard !perturbed else { return }
            perturbed = true
            guard var state = TaskContextStateManager.load(taskFolder: folder) else { return }
            state.turns.append(TaskContextState.Turn(
                turn: 42,
                ask: "written between load and apply",
                summary: "",
                filesChanged: [],
                blockers: [],
                runStatus: "completed"
            ))
            _ = TaskContextStateManager.saveState(state, taskFolder: folder)
        }
        defer { TaskContextStateManager.interleaveForTesting = nil }

        await TaskContextStateManager.refreshLoadingOffMainActor(task: fixture.task)

        #expect(TaskContextStateManager.revalidationRetryCountForTesting == 1, "the stale load must be retried")
        #expect(TaskContextStateManager.fallbackCountForTesting == 0, "the retry must not cost a main-actor redo")
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.turns.contains { $0.ask == "written between load and apply" })
    }

    nonisolated private static func corruptCopies(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.contains(".corrupt-") }
    }

    private func modificationDate(of url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return try #require(values.contentModificationDate)
    }

    private func makeFixture(_ suffix: String) throws -> Fixture {
        // Objective assessments are only carried across a refresh with drift
        // detection on; the seeded state in the equivalence test depends on it.
        let defaults = UserDefaults.standard
        let driftKey = AppStorageKeys.objectiveDriftDetectionEnabled
        let originalDrift = defaults.object(forKey: driftKey) as? Bool
        defaults.set(true, forKey: driftKey)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-offmain-refresh-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [configuration]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Off-main refresh", primaryPath: root.path)
        let task = AgentTask(title: "Off-main refresh", goal: "Original goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        try context.save()
        // Establishes the task folder and its initial `current_state.json`, so
        // tests start from a task that already has durable state.
        TaskContextStateManager.refresh(task: task)
        return Fixture(root: root, container: container, task: task, restoreDrift: {
            if let originalDrift {
                defaults.set(originalDrift, forKey: driftKey)
            } else {
                defaults.removeObject(forKey: driftKey)
            }
        })
    }

    private struct Fixture {
        let root: URL
        /// Retained for the fixture's lifetime: letting the container go
        /// deallocates the store out from under the task.
        let container: ModelContainer
        let task: AgentTask
        let restoreDrift: () -> Void

        var folder: String {
            TaskWorkspaceAccess(task: task).taskFolder
        }

        func cleanup() {
            restoreDrift()
            try? FileManager.default.removeItem(at: root)
            _ = container
        }
    }
}
