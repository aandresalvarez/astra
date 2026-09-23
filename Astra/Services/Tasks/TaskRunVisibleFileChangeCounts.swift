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
/// Now the root is resolved once per rebuild, the rebuild runs detached, and a
/// run is recounted only when its changes move: each entry remembers the
/// `fileChangesJSONLength` it was counted at, which is the JSON the thread
/// snapshot decodes those changes from.
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
    struct Inputs: Equatable, Sendable {
        let taskID: UUID
        let workspacePath: String
        let runs: [Run]
    }

    /// A run to count, with its paths taken on the main actor.
    struct Pending: Sendable {
        let id: UUID
        let fileChangesJSONLength: Int
        let paths: [String]
    }

    private(set) var taskID: UUID?
    private(set) var workspacePath = ""
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
        let sameFolder = taskID == inputs.taskID && workspacePath == inputs.workspacePath
        return Set(inputs.runs.lazy.filter { run in
            !sameFolder || entries[run.id]?.fileChangesJSONLength != run.fileChangesJSONLength
        }.map(\.id))
    }

    /// Fresh counts over the ones still valid, keeping only runs in `inputs`.
    func merging(_ counted: [UUID: Entry], for inputs: Inputs) -> TaskRunVisibleFileChangeCounts {
        let sameFolder = taskID == inputs.taskID && workspacePath == inputs.workspacePath
        var next = TaskRunVisibleFileChangeCounts()
        next.taskID = inputs.taskID
        next.workspacePath = inputs.workspacePath
        for run in inputs.runs {
            if let fresh = counted[run.id] {
                next.entries[run.id] = fresh
            } else if sameFolder, let kept = entries[run.id] {
                next.entries[run.id] = kept
            }
        }
        return next
    }

    /// Counts `pending` off the main actor, resolving the task folder once for
    /// every path rather than once per path.
    static func counted(_ pending: [Pending], taskFolder: String) -> [UUID: Entry] {
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(taskFolder)
        var counts: [UUID: Entry] = [:]
        for run in pending {
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
}
