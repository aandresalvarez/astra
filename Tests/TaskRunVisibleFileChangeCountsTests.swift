import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

/// The run footer's "changed files" count moved out of `TaskMainView.body`,
/// where every keystroke paid a `stat` and two symlink walks per changed path
/// for it. What matters now: the hoisted root gives the same verdicts, and a
/// rebuild recounts only the runs whose changes moved.
@Suite("Task run visible file-change counts")
struct TaskRunVisibleFileChangeCountsTests {
    /// Resolved up front: `/tmp` is a symlink to `/private/tmp`, and the test
    /// is about the counter, not the temporary directory.
    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("astra-visible-file-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relativePath: String, under root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func run(_ id: UUID, length: Int, paths: [String] = []) -> TaskRunVisibleFileChangeCounts.Pending {
        TaskRunVisibleFileChangeCounts.Pending(id: id, fileChangesJSONLength: length, paths: paths)
    }

    @Test("Hoisting the root gives the verdicts the per-path resolution gave")
    func hoistedRootMatchesPerPathResolution() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskFolder = root.appendingPathComponent("tasks/T1")

        let paths = [
            try write("tasks/T1/report.md", under: root),
            try write("tasks/T1/outputs/turn_001.md", under: root),
            try write("tasks/T1/.venv/lib/python3.12/site.py", under: root),
            try write("tasks/T1/node_modules/pkg/index.js", under: root),
            try write("tasks/T1/diagnostics/run.log", under: root),
            try write("src/main.swift", under: root),
            taskFolder.appendingPathComponent("deleted.md").path
        ]

        // What `userFacingFileChangeCount` computed, resolving the root per path.
        let perPath = paths.filter { path in
            guard let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: taskFolder.path) else {
                return true
            }
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(relative, context: .taskFolder) != nil
        }.count
        let hoisted = TaskRunVisibleFileChangeCounts.visibleCount(
            of: paths,
            under: TaskOutputArtifactPathPolicy.ResolvedRoot(taskFolder.path)
        )

        #expect(hoisted == perPath)
        // The deliverable, the workspace file and the deleted deliverable show;
        // the turn output, both dependency folders and the diagnostic do not.
        #expect(hoisted == 3)
    }

    @Test("Only runs that are new or whose changes moved are recounted")
    func onlyMovedRunsAreRecounted() {
        let taskID = UUID()
        let steady = UUID()
        let growing = UUID()
        let fresh = UUID()
        let first = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID,
            workspacePath: "/workspace",
            folderRevision: 0,
            runs: [.init(id: steady, fileChangesJSONLength: 10), .init(id: growing, fileChangesJSONLength: 20)]
        )
        let cache = TaskRunVisibleFileChangeCounts().merging(
            TaskRunVisibleFileChangeCounts.counted(
                [run(steady, length: 10, paths: ["/elsewhere/a"]), run(growing, length: 20)],
                taskFolder: "/workspace/.astra/tasks/T1"
            ),
            for: first
        )
        #expect(cache.runsNeedingCount(first).isEmpty)

        let second = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID,
            workspacePath: "/workspace",
            folderRevision: 0,
            runs: [
                .init(id: steady, fileChangesJSONLength: 10),
                .init(id: growing, fileChangesJSONLength: 25),
                .init(id: fresh, fileChangesJSONLength: 5)
            ]
        )
        #expect(cache.runsNeedingCount(second) == [growing, fresh])

        // Another workspace means another task folder: nothing carries over.
        let moved = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID, workspacePath: "/other", folderRevision: 0, runs: first.runs
        )
        #expect(cache.runsNeedingCount(moved) == [steady, growing])

        // A legacy folder migrating moves only the revision; every path is
        // judged against the new root, so every run is recounted.
        let migrated = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID, workspacePath: "/workspace", folderRevision: 1, runs: first.runs
        )
        #expect(cache.runsNeedingCount(migrated) == [steady, growing])
        let recounted = cache.merging(
            TaskRunVisibleFileChangeCounts.counted(
                [run(steady, length: 10), run(growing, length: 20)],
                taskFolder: "/workspace/.astra/tasks/T1"
            ),
            for: migrated
        )
        #expect(recounted.runsNeedingCount(migrated).isEmpty)
    }

    /// The count runs off the main actor but stays attached to the
    /// `.task(id:)` that asked for it, so a rebuild superseded before counting
    /// began touches no path. A detached task would have finished every one.
    @Test("A superseded count skips the work")
    func supersededCountSkipsTheWork() async {
        let id = UUID()
        let pending = [run(id, length: 10, paths: ["/elsewhere/a"])]

        let live = await TaskRunVisibleFileChangeCounts.counted(pending, workspacePath: "/workspace", taskID: UUID())
        #expect(live?[id]?.count == 1)

        let superseded = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TaskRunVisibleFileChangeCounts.counted(pending, workspacePath: "/workspace", taskID: UUID())
        }.value
        #expect(superseded == nil)

        // Once started, it stops between runs rather than finishing them.
        let stopped = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return TaskRunVisibleFileChangeCounts.counted(pending, taskFolder: "/workspace/.astra/tasks/T1")
        }.value
        #expect(stopped.isEmpty)
    }

    @Test("A run's last count stands until its recount lands, and gone runs drop out")
    func lastCountStandsUntilReplaced() {
        let taskID = UUID()
        let kept = UUID()
        let dropped = UUID()
        let first = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID,
            workspacePath: "/workspace",
            folderRevision: 0,
            runs: [.init(id: kept, fileChangesJSONLength: 10), .init(id: dropped, fileChangesJSONLength: 10)]
        )
        let cache = TaskRunVisibleFileChangeCounts().merging(
            TaskRunVisibleFileChangeCounts.counted(
                [run(kept, length: 10, paths: ["/elsewhere/a", "/elsewhere/b"]), run(dropped, length: 10)],
                taskFolder: "/workspace/.astra/tasks/T1"
            ),
            for: first
        )
        #expect(cache.count(for: kept) == 2)
        #expect(cache.count(for: UUID()) == nil)

        // The run grew; until its recount arrives, the old count still shows.
        let second = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID,
            workspacePath: "/workspace",
            folderRevision: 0,
            runs: [.init(id: kept, fileChangesJSONLength: 30)]
        )
        #expect(cache.count(for: kept) == 2)
        let recounted = cache.merging(
            TaskRunVisibleFileChangeCounts.counted(
                [run(kept, length: 30, paths: ["/elsewhere/a", "/elsewhere/b", "/elsewhere/c"])],
                taskFolder: "/workspace/.astra/tasks/T1"
            ),
            for: second
        )
        #expect(recounted.count(for: kept) == 3)
        #expect(recounted.count(for: dropped) == nil)
        #expect(recounted.runsNeedingCount(second).isEmpty)

        // A run can leave the snapshot with nothing new to count. Merging
        // nothing still drops it, which is how the view prunes then.
        let onlyKept = TaskRunVisibleFileChangeCounts.Inputs(
            taskID: taskID, workspacePath: "/workspace", folderRevision: 0, runs: [.init(id: kept, fileChangesJSONLength: 10)]
        )
        #expect(cache.runsNeedingCount(onlyKept).isEmpty)
        let pruned = cache.merging([:], for: onlyKept)
        #expect(pruned.count(for: kept) == 2)
        #expect(pruned.count(for: dropped) == nil)
    }
}
