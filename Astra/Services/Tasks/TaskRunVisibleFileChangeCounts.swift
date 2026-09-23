import Foundation
import ASTRAPersistence

/// How many of each run's file changes a user would recognize: the number on
/// the "changed files" button in a finished run's footer.
///
/// **Why this is cached.** It used to be counted inside `TaskMainView`'s agent
/// bubble, which `body` builds for every run on every pass, including the pass
/// each keystroke in the composer triggers. Per bubble that cost a `stat` to
/// find the task folder, and per changed path a fresh `ResolvedRoot` (a
/// symlink walk of the task folder) plus a symlink walk of the path itself.
/// `TaskDecisionArtifactPathFilter` has the account of how those walks add up.
///
/// Now the root is resolved once per rebuild, the count runs off the main
/// actor, and a run is recounted only when its changes move: each entry
/// remembers the `fileChangesJSONLength` it was counted at, which is the JSON
/// the thread snapshot decodes those changes from. Every run is recounted when
/// the task folder moves off the legacy layout; the cache remembers the folder
/// its counts were judged against, so the view can tell.
struct TaskRunVisibleFileChangeCounts: Equatable {
    struct Entry: Equatable, Sendable {
        let fileChangesJSONLength: Int
        let count: Int
    }

    /// One run as the key sees it.
    struct Run: Equatable, Sendable {
        let id: UUID
        let fileChangesJSONLength: Int
    }

    /// The `.task(id:)` key: values `body` already holds, no filesystem.
    /// `folderRevision` moves when the folder these counts were judged against
    /// turns out to have moved off the legacy layout, which changes the root
    /// every path is judged by without moving anything else here.
    struct Inputs: Equatable, Sendable {
        let taskID: UUID
        let workspacePath: String
        let folderRevision: Int
        let runs: [Run]
    }

    /// A run to count, with its paths taken on the main actor.
    struct Pending: Sendable {
        let id: UUID
        let fileChangesJSONLength: Int
        let paths: [String]
    }

    /// What one rebuild counted, and the task folder it judged the paths by.
    struct Counted: Sendable {
        let entries: [UUID: Entry]
        let taskFolder: String
    }

    private(set) var taskID: UUID?
    private(set) var workspacePath = ""
    private(set) var folderRevision = 0
    /// The folder the entries were judged against; empty before the first
    /// rebuild lands.
    private(set) var taskFolder = ""
    private(set) var entries: [UUID: Entry] = [:]

    /// The last count for a run, or nil before its first one lands. A count
    /// taken at an older length stands until its recount replaces it, so the
    /// button does not blink out while a run's changes grow.
    func count(for runID: UUID) -> Int? {
        entries[runID]?.count
    }

    /// Runs that are new since the last rebuild or whose changes have moved;
    /// every run, if the task folder itself may have.
    func runsNeedingCount(_ inputs: Inputs) -> Set<UUID> {
        let sameFolder = countedAgainstSameFolder(as: inputs)
        return Set(inputs.runs.lazy.filter { run in
            !sameFolder || entries[run.id]?.fileChangesJSONLength != run.fileChangesJSONLength
        }.map(\.id))
    }

    /// Fresh counts over the ones still valid, keeping only runs in `inputs`.
    /// `folder` is what the fresh counts were judged against; without one, as
    /// when only pruning, the cache keeps the folder it had.
    func merging(
        _ counted: [UUID: Entry],
        for inputs: Inputs,
        countedIn folder: String? = nil
    ) -> TaskRunVisibleFileChangeCounts {
        let sameFolder = countedAgainstSameFolder(as: inputs)
        var next = TaskRunVisibleFileChangeCounts()
        next.taskID = inputs.taskID
        next.workspacePath = inputs.workspacePath
        next.folderRevision = inputs.folderRevision
        next.taskFolder = folder ?? (sameFolder ? taskFolder : "")
        for run in inputs.runs {
            if let fresh = counted[run.id] {
                next.entries[run.id] = fresh
            } else if sameFolder, let kept = entries[run.id] {
                next.entries[run.id] = kept
            }
        }
        return next
    }

    /// Whether these counts were judged against a folder the task no longer
    /// resolves to. Nothing counted yet is never stale: the first rebuild
    /// checks its own folder when it lands.
    func isStale(forFolder currentFolder: String) -> Bool {
        !taskFolder.isEmpty && taskFolder != currentFolder
    }

    /// Whether counts judged against `folder` can join these under `inputs`.
    /// Not when the merge would keep entries judged against another folder:
    /// a legacy folder migrates wherever the task folder is first ensured, a
    /// run launch as much as a context refresh, and a run counted after that
    /// would otherwise vouch for runs counted before it. Only a full recount,
    /// under a new `folderRevision`, replaces those.
    func canMerge(countedIn folder: String, for inputs: Inputs) -> Bool {
        !countedAgainstSameFolder(as: inputs) || !isStale(forFolder: folder)
    }

    private func countedAgainstSameFolder(as inputs: Inputs) -> Bool {
        taskID == inputs.taskID
            && workspacePath == inputs.workspacePath
            && folderRevision == inputs.folderRevision
    }

    /// Counts `pending` off the main actor, resolving the task folder once for
    /// every path rather than once per path.
    static func counted(_ pending: [Pending], taskFolder: String) -> [UUID: Entry] {
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(taskFolder)
        var counts: [UUID: Entry] = [:]
        for run in pending {
            // A superseded rebuild stops between runs. Outside a task this is
            // always false, so a synchronous caller counts everything.
            if Task.isCancelled { break }
            counts[run.id] = Entry(
                fileChangesJSONLength: run.fileChangesJSONLength,
                count: visibleCount(of: run.paths, under: root)
            )
        }
        return counts
    }

    static func visibleCount(of paths: [String], under root: TaskOutputArtifactPathPolicy.ResolvedRoot) -> Int {
        paths.filter { path in
            // Outside the task folder: a workspace file the run edited, which
            // is always shown. Only paths inside go through the policy.
            guard let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: root) else {
                return true
            }
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }.count
    }

    /// `counted` with the folder resolved here, off the main actor and
    /// cancelled with the caller: nil if the rebuild that asked was superseded
    /// before counting began. A `Task.detached` would finish every superseded
    /// count; see `TaskMissionControlSnapshot.Source.loaded`.
    nonisolated static func counted(_ pending: [Pending], workspacePath: String, taskID: UUID) async -> Counted? {
        guard !Task.isCancelled else { return nil }
        let folder = TaskFolderResolvingAdapter.taskFolder(workspacePath: workspacePath, taskID: taskID)
        let counts = counted(pending, taskFolder: folder)
        // Counting stops early once cancelled, so what it returned then is partial.
        return Task.isCancelled ? nil : Counted(entries: counts, taskFolder: folder)
    }
}
