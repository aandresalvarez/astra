import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence

@Suite("Task run protocol marker backfill")
struct TaskRunProtocolMarkerBackfillServiceTests {
    @MainActor
    @Test("Backfill resolves never-scanned runs and then finds nothing to do")
    func backfillResolvesNeverScannedRunsOnce() throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext
        let runs = try context.fetch(FetchDescriptor<TaskRun>())
        #expect(runs.count == 3)
        #expect(runs.allSatisfy { $0.hasProtocolEvents == nil })

        let first = TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)
        #expect(first == .init(scanned: 3, markerBearing: 1, completed: true))

        for run in try context.fetch(FetchDescriptor<TaskRun>()) {
            #expect(run.hasProtocolEvents == run.output.contains("ASTRA_EVENT"))
        }

        // The predicate only selects nil rows, so a repeat pass costs one empty
        // fetch rather than a second scan of every output blob.
        let second = TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)
        #expect(second == .init(scanned: 0, markerBearing: 0, completed: true))
    }

    @MainActor
    @Test("Build gate skips a backfill that already ran for this build")
    func buildGateSkipsAnAlreadyCompletedBackfill() throws {
        let root = try makeLegacyStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try migratedContainer(at: root)
        let context = container.mainContext
        let suiteName = "astra.tests.marker-backfill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("42", forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild)

        TaskRunProtocolMarkerBackfillService.backfillIfNeeded(
            modelContext: context,
            currentBuild: "42",
            defaults: defaults
        )
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).allSatisfy { $0.hasProtocolEvents == nil })

        // A new build re-arms the pass, which is how a store imported or
        // recovered since the last run still gets resolved.
        TaskRunProtocolMarkerBackfillService.backfillIfNeeded(
            modelContext: context,
            currentBuild: "43",
            defaults: defaults
        )
        #expect(try context.fetch(FetchDescriptor<TaskRun>()).allSatisfy { $0.hasProtocolEvents != nil })
        #expect(defaults.string(forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild) == "43")
    }

    @MainActor
    @Test("Plan recovery keeps every never-scanned run and drops proven-clean ones")
    func planRecoveryNarrowsOnlyAfterTheBackfill() throws {
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

        TaskRunProtocolMarkerBackfillService.backfill(modelContext: context)

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
    @MainActor
    private func makeLegacyStoreRoot() throws -> URL {
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
        let outputs = [#"ASTRA_EVENT {"v":1,"type":"plan.step.completed"}"#, "ordinary output", ""]
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
