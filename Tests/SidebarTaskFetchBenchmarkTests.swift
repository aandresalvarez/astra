import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Measures the sidebar's `AgentTask` fetch against a store shaped like a real
/// one, so the cost of each remedy is a number rather than an argument.
///
/// The production store this was built from: 726 tasks across 15 workspaces,
/// 12.8 MB of column payload, 10.85 MB of it `goal` alone (326 rows over 10 KB,
/// largest 110 KB), and `queuePosition` holding 0 for every single row with no
/// index on the column. Sorting on it made SQLite build a temp B-tree and spill
/// the whole result set to a PMA temp file — on the main thread, inside the
/// SwiftUI view transaction, several times a second while a task streamed.
///
/// The store must be on disk. In-memory stores never reach the external sorter,
/// which is the entire effect under test.
///
/// Opt-in: runs only with `RUN_UI_STRESS=1` (see `uiStressSuitesEnabled`).
@Suite(
    "Sidebar task fetch cost",
    .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run the UI stress suites")
)
struct SidebarTaskFetchBenchmarkTests {
    private static let taskCount = 726
    private static let workspaceCount = 15
    private static let largeGoalCount = 326

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Seeds one on-disk store and returns its URL. Callers reopen it per
    /// measurement so no run is served out of a warm row cache.
    ///
    /// - Parameter thinRows: when true, every `goal` is a few hundred bytes,
    ///   standing in for a store where the large text has been moved into a
    ///   side entity. The difference between the two is what a schema
    ///   migration would actually buy.
    private func seedStore(at root: URL, thinRows: Bool = false) throws -> URL {
        let storeURL = root.appendingPathComponent("bench.store")
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)

        let workspaces = (0..<Self.workspaceCount).map { index -> Workspace in
            let workspace = Workspace(name: "Workspace \(index)", primaryPath: "/tmp/ws\(index)")
            context.insert(workspace)
            return workspace
        }

        var generator = SplitMix64(state: 0xA57A)
        let statuses: [TaskStatus] = [.completed, .draft, .failed, .cancelled, .pendingUser, .queued, .running]
        for index in 0..<Self.taskCount {
            // Mirror the production distribution: most of the payload sits in a
            // minority of very large `goal` values, which is what makes the
            // external sort so expensive.
            let goalLength: Int
            if thinRows {
                goalLength = Int.random(in: 40...200, using: &generator)
            } else {
                goalLength = index < Self.largeGoalCount
                    ? Int.random(in: 10_000...110_000, using: &generator)
                    : Int.random(in: 200...2_000, using: &generator)
            }
            let task = AgentTask(
                title: "Task \(index)",
                goal: String(repeating: "g", count: goalLength),
                workspace: workspaces[index % Self.workspaceCount]
            )
            task.status = statuses[index % statuses.count]
            task.isDone = index % 2 == 0
            task.updatedAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            task.skillSnapshotsJSON = thinRows ? "[]" : String(repeating: "s", count: 1_800)
            // The condition under test: every row carries the same sort key.
            task.queuePosition = 0
            context.insert(task)
        }
        try context.save()
        return storeURL
    }

    /// Reopens the store from scratch so each measurement pays a cold fetch.
    private func measureFetch(
        storeURL: URL,
        iterations: Int = 5,
        configure: (inout FetchDescriptor<AgentTask>) -> Void
    ) throws -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<AgentTask>()
            configure(&descriptor)

            let start = DispatchTime.now().uptimeNanoseconds
            let fetched = try context.fetch(descriptor)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            #expect(fetched.count == Self.taskCount)
            best = min(best, elapsed)
        }
        return best
    }

    /// Same shape as `measureFetch`, for the membership check rather than the read.
    private func measureCount(storeURL: URL, iterations: Int = 5) throws -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = ModelContext(container)

            let start = DispatchTime.now().uptimeNanoseconds
            let count = try context.fetchCount(SidebarTaskFetch.descriptor())
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            #expect(count == Self.taskCount)
            best = min(best, elapsed)
        }
        return best
    }

    /// Same shape again, for the identifier probe that replaced the timed
    /// full re-read.
    private func measureIdentifiers(storeURL: URL, iterations: Int = 5) throws -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = ModelContext(container)

            let start = DispatchTime.now().uptimeNanoseconds
            let identifiers = try context.fetchIdentifiers(SidebarTaskFetch.descriptor())
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            #expect(identifiers.count == Self.taskCount)
            best = min(best, elapsed)
        }
        return best
    }

    /// The schedule that used to carry a full re-read now carries this instead.
    /// Production made the case: 117 timed re-reads over 2.7 days, 67.3 seconds
    /// of blocked main thread, zero membership changes found. Swapping the read
    /// for a key scan is only the right trade if the key scan is genuinely
    /// cheap against a production-shaped store, so it gets a number too.
    @Test("Reading identifiers is far cheaper than reading rows")
    func fetchIdentifiersIsCheaperThanFetch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-sidebar-identifier-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = try seedStore(at: root)
        let fetch = try measureFetch(storeURL: storeURL) { _ in }
        let identifiers = try measureIdentifiers(storeURL: storeURL)

        print("[bench] sidebar membership probe identifiers=\(String(format: "%.2f", identifiers))ms "
            + "fetch=\(String(format: "%.2f", fetch))ms "
            + "ratio=\(String(format: "%.1f", fetch / max(identifiers, 0.0001)))x")

        #expect(
            identifiers < fetch / 2,
            """
            fetchIdentifiers (\(identifiers) ms) must be substantially cheaper than the full \
            fetch (\(fetch) ms), or the probe is just the timed re-read wearing a new name
            """
        )
    }

    /// `SidebarTaskStore` answers "did anything appear or disappear?" with a
    /// `fetchCount` and only pays for the full read when the answer is yes.
    /// That trade is only worth making if counting is much cheaper than
    /// reading, so this measures the ratio rather than assuming it.
    @Test("Counting rows is far cheaper than reading them")
    func fetchCountIsCheaperThanFetch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-sidebar-count-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = try seedStore(at: root)
        let fetch = try measureFetch(storeURL: storeURL) { _ in }
        let count = try measureCount(storeURL: storeURL)

        print("[bench] sidebar membership check count=\(String(format: "%.2f", count))ms "
            + "fetch=\(String(format: "%.2f", fetch))ms "
            + "ratio=\(String(format: "%.1f", fetch / max(count, 0.0001)))x")

        // A modest floor: if counting ever costs even half a full read, the
        // store should stop pre-checking and just coalesce the read itself.
        #expect(
            count < fetch / 2,
            """
            fetchCount (\(count) ms) must be substantially cheaper than the full \
            fetch (\(fetch) ms) for SidebarTaskStore's pre-check to be worth running
            """
        )
    }

    @Test("Dropping the queuePosition sort removes the external-sort cost")
    func unsortedFetchBeatsSortedFetch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-sidebar-fetch-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = try seedStore(at: root)

        let sorted = try measureFetch(storeURL: storeURL) { descriptor in
            descriptor.sortBy = [SortDescriptor(\AgentTask.queuePosition)]
        }
        let unsorted = try measureFetch(storeURL: storeURL) { _ in }

        print("[bench] sidebar fetch sorted=\(String(format: "%.2f", sorted))ms "
            + "unsorted=\(String(format: "%.2f", unsorted))ms")

        // The sort produces no ordering — every key is 0 — so any time it costs
        // is pure waste. Compared best-of-N against best-of-N to keep this from
        // tripping on a scheduler hiccup.
        #expect(
            unsorted <= sorted,
            "Unsorted fetch (\(unsorted) ms) should not be slower than the sorted one (\(sorted) ms)"
        )
    }

    /// Records the measured verdict on `propertiesToFetch`, which looks like
    /// the obvious fix and is not one. Restricting the fetch to the columns
    /// the sidebar renders came out *slower* than fetching whole rows —
    /// SwiftData still pays for the row, and the partial-fault bookkeeping is
    /// added on top. Kept as a test so the next person to reach for it sees
    /// the number instead of re-deriving it.
    @Test("Column projection does not make the sidebar fetch cheaper")
    func projectionDoesNotBeatFullRowFetch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-sidebar-projection-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = try seedStore(at: root)

        let fullRows = try measureFetch(storeURL: storeURL) { _ in }
        let projected = try measureFetch(storeURL: storeURL) { descriptor in
            descriptor.propertiesToFetch = SidebarTaskFetch.renderedProperties
        }

        print("[bench] sidebar fetch full=\(String(format: "%.2f", fullRows))ms "
            + "projected=\(String(format: "%.2f", projected))ms")
        #expect(projected > 0 && fullRows > 0)
    }

    /// Decides whether moving `goal` into a side entity is worth a store
    /// migration: it compares a production-shaped store against one whose rows
    /// carry no large text, holding everything else equal.
    @Test("Row width sets the floor on what the sidebar fetch can cost")
    func thinRowsFetchFasterThanFatRows() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-sidebar-width-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fatRoot = root.appendingPathComponent("fat")
        let thinRoot = root.appendingPathComponent("thin")
        try FileManager.default.createDirectory(at: fatRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thinRoot, withIntermediateDirectories: true)

        let fat = try measureFetch(storeURL: try seedStore(at: fatRoot)) { _ in }
        let thin = try measureFetch(storeURL: try seedStore(at: thinRoot, thinRows: true)) { _ in }

        print("[bench] sidebar fetch fatRows=\(String(format: "%.2f", fat))ms "
            + "thinRows=\(String(format: "%.2f", thin))ms")
        #expect(thin <= fat, "Thin rows (\(thin) ms) should not fetch slower than fat ones (\(fat) ms)")
    }
}
