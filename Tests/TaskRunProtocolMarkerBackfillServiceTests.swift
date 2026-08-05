import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence

/// Counts how many turns a competing main-actor job got while another
/// main-actor job was running.
@MainActor
private final class MainActorTicker {
    var value = 0
}

@Suite("Task run protocol marker backfill")
struct TaskRunProtocolMarkerBackfillServiceTests {
    @MainActor
    @Test("Backfill resolves never-scanned runs and then finds nothing to do")
    func backfillResolvesNeverScannedRunsOnce() async throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext
        let runs = try context.fetch(FetchDescriptor<TaskRun>())
        #expect(runs.count == 3)
        #expect(runs.allSatisfy { $0.hasProtocolEvents == nil })

        let first = await TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)
        #expect(first == .init(scanned: 3, markerBearing: 1, completed: true))

        for run in try context.fetch(FetchDescriptor<TaskRun>()) {
            #expect(run.hasProtocolEvents == run.output.contains("ASTRA_EVENT"))
        }

        // A repeat pass - and a fresh install, which is the same shape - stops
        // at the aggregate probe. `skippedEmptyStore` is how that is visible:
        // nothing is fetched, so no managed object is materialized at all.
        let second = await TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)
        #expect(second == .init(completed: true, skippedEmptyStore: true))
    }

    @MainActor
    @Test("Backfill pages past the batch size and terminates")
    func backfillWalksEveryBatchUntilTheStoreIsResolved() async throws {
        let extraRuns = 250
        let root = try makeLegacyStoreRoot(additionalCleanRuns: extraRuns)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext
        let total = 3 + extraRuns
        // The multi-batch loop only runs when the store outgrows one page.
        #expect(total > TaskRunProtocolMarkerBackfillService.batchSize)
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).count == total)

        let outcome = await TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)
        #expect(outcome == .init(scanned: total, markerBearing: 1, completed: true))
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).allSatisfy { $0.hasProtocolEvents != nil })

        let second = await TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)
        #expect(second == .init(completed: true, skippedEmptyStore: true))
    }

    @MainActor
    @Test("Backfill hands the main actor back between batches")
    func backfillYieldsTheMainActorBetweenBatches() async throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext

        // Enqueued, not started: an unstructured Task only gets the main actor
        // once the current job suspends. If the pass never suspends, this loop
        // never runs a single iteration - which is precisely the launch-path
        // freeze a whole-store sweep produces on the first launch after an
        // update. `batchSize: 1` makes every run its own batch boundary.
        let ticker = MainActorTicker()
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                ticker.value += 1
                await Task.yield()
            }
        }
        let outcome = await TaskRunProtocolMarkerBackfillService.backfill(
            modelContext: context,
            batchSize: 1
        )
        observer.cancel()

        #expect(outcome == .init(scanned: 3, markerBearing: 1, completed: true))
        #expect(ticker.value >= 1)
    }

    @Test("The one-time sweep is sequenced after crash recovery, not in front of it")
    func startupSweepRunsAfterOrphanedRunRecovery() throws {
        let root = try TestRepositoryRoot.resolve()
        let app = try String(
            contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"),
            encoding: .utf8
        )
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )

        // A run a crash left `.running` keeps occupying the queue until
        // recovery reclaims it, so recovery must never queue behind a
        // whole-store performance sweep.
        let workStart = try #require(app.range(of: "public static func runDeferredStartupWork("))
        let migrationsStart = try #require(app.range(of: "public static func runDeferredStartupMigrations("))
        let deferredWorkBody = app[workStart.upperBound..<migrationsStart.lowerBound]
        #expect(deferredWorkBody.contains("recoverOrphanedRunningRuns"))
        #expect(!deferredWorkBody.contains("TaskRunProtocolMarkerBackfillService"))

        let replay = try #require(contentView.range(of: "replayRecoveredTurns"))
        let sweep = try #require(contentView.range(of: "runDeferredStartupMigrations"))
        #expect(replay.lowerBound < sweep.lowerBound)
    }

    @MainActor
    @Test("Build gate skips a backfill that already ran for this build")
    func buildGateSkipsAnAlreadyCompletedBackfill() async throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext
        let suiteName = "astra.tests.marker-backfill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("42", forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild)

        await TaskRunProtocolMarkerBackfillService.backfillIfNeeded(
            modelContext: context,
            currentBuild: "42",
            defaults: defaults
        )
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).allSatisfy { $0.hasProtocolEvents == nil })

        // A new build re-arms the pass, which is how a store imported or
        // recovered since the last run still gets resolved.
        await TaskRunProtocolMarkerBackfillService.backfillIfNeeded(
            modelContext: context,
            currentBuild: "43",
            defaults: defaults
        )
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).allSatisfy { $0.hasProtocolEvents != nil })
        #expect(defaults.string(forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild) == "43")
    }

    @MainActor
    @Test("Plan recovery keeps every never-scanned run and drops proven-clean ones")
    func planRecoveryNarrowsOnlyAfterTheBackfill() async throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext
        let task = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        let markerRunID = try #require(
            try context.fetch(FetchDescriptor<TaskRun>()).first { $0.output.contains("ASTRA_EVENT") }?.id
        )

        // Before the backfill every legacy row is a candidate, so no recovered
        // plan progress can be lost while the flag is still unknown.
        #expect(try TaskPlanStateReader.read(taskID: task.id, modelContext: context).recoveryRuns.count == 3)

        await TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)

        // After it, SQLite rejects the clean rows instead of handing their
        // output blobs to the main actor.
        let after = try TaskPlanStateReader.read(taskID: task.id, modelContext: context)
        #expect(after.recoveryRuns.map(\.id) == [markerRunID])
    }

    @MainActor
    @Test("A `!= false` predicate would silently drop never-scanned runs")
    func notEqualFalsePredicateDropsNeverScannedRuns() throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext

        // This is the shape `TaskPlanStateReader` deliberately does not use.
        // SQL three-valued logic makes `NULL != 0` unknown, so every pre-V17
        // run disappears from plan recovery. The reader spells the nil branch
        // out instead; this test is what stops it being "simplified" back.
        let dropped = try context.fetch(FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.hasProtocolEvents != false }
        ))
        #expect(dropped.isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).count == 3)
    }

    /// Writes an on-disk V16 store. Migrating it forward is the only way to
    /// obtain the `nil` flag this service exists to resolve: `TaskRun(task:)`
    /// always pins the flag and both stored properties are `private(set)`.
    ///
    /// `additionalCleanRuns` pads the store past `batchSize` so the paging loop
    /// is actually executed rather than short-circuited by a single-page store.
    @MainActor
    private func makeLegacyStoreRoot(additionalCleanRuns: Int = 0) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-marker-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV16.self),
            configurations: [ModelConfiguration(url: storeURL(in: root))]
        )
        let context = container.mainContext
        let task = ASTRASchemaV14Models.AgentTask()
        task.title = "Legacy task"
        task.goal = "Resolve protocol marker flags"
        context.insert(task)
        var outputs = [#"ASTRA_EVENT {"v":1,"type":"plan.step.completed"}"#, "ordinary output", ""]
        outputs += (0..<additionalCleanRuns).map { "clean output \($0)" }
        for (index, output) in outputs.enumerated() {
            let run = ASTRASchemaV14Models.TaskRun()
            run.task = task
            run.startedAt = Date(timeIntervalSince1970: Double(index + 1))
            run.output = output
            context.insert(run)
        }
        try context.save()
        return root
    }

    /// Returns the container, not its `mainContext`: the context does not keep
    /// the container alive, and reading through a released one traps in
    /// SwiftData.
    @MainActor
    private func migratedContainer(at root: URL) throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL(in: root))]
        )
    }

    private func storeURL(in root: URL) -> URL {
        root.appendingPathComponent("store.store")
    }
}
