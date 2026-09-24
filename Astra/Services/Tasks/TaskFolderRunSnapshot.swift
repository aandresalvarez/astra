import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The size and modified time of every file a user would see in a task
/// folder, taken just before a provider starts and again after it exits, so
/// the run owns every file it created, edited, or removed — whatever wrote it.
///
/// Tool events only cover files a provider wrote through its own Write and
/// Edit tools. A shell command, a Python script, or `bq` writing into the task
/// folder left no record on the run, and neither did a deletion. The inferred
/// detector does not cover the gap either: it runs for some providers only,
/// and it ignores `.astra/`, which is where task folders live. In one
/// production task, 76 of 90 runs recorded no file changes, and 515 of 529
/// files had no run that produced them.
///
/// Only metadata is read, never contents, so a folder of a few hundred files
/// costs milliseconds, and the walk runs off the main actor. The visibility
/// rules are the Files shelf's (`TaskOutputArtifactPathPolicy`), so ASTRA's
/// own bookkeeping (`outputs/`, `inputs/`, `current_state.*`, `diagnostics/`)
/// and dependency trees never count as the run's work. Hidden files are
/// skipped, which keeps Finder's `.DS_Store` writes out of every run.
struct TaskFolderRunSnapshot: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let size: Int
        let modifiedAt: Date?
    }

    struct Change: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case created
            case modified
            case removed

            fileprivate var recordingPriority: Int {
                switch self {
                case .created: 0
                case .modified: 1
                case .removed: 2
                }
            }

            var storedKind: StoredFileChangeKind {
                switch self {
                case .created: .discovered
                case .modified: .modified
                case .removed: .removed
                }
            }
        }

        let relativePath: String
        let kind: Kind
        let modifiedAt: Date?
    }

    /// Entries walked, of any kind, before the snapshot gives up. Past this a
    /// folder is holding data rather than work product, and two partial walks
    /// cannot be compared: a file past the cutoff would read as removed.
    static let entryLimit = 50_000

    /// Observed changes recorded on one run. Each is about 200 bytes of JSON,
    /// and the thread stops decoding a run's changes past 256 KB, which would
    /// hide the tool changes stored beside them. A run that touches more files
    /// than this is a bulk operation nobody reviews file by file; new and
    /// edited files are kept ahead of removals.
    static let recordedChangeLimit = 250

    let root: TaskOutputArtifactPathPolicy.ResolvedRoot
    /// Keyed by path relative to `root`.
    let entries: [String: Entry]

    func changes(since before: TaskFolderRunSnapshot) -> [Change] {
        var changes: [Change] = []
        for (relativePath, entry) in entries {
            if let previous = before.entries[relativePath] {
                guard previous != entry else { continue }
                changes.append(Change(relativePath: relativePath, kind: .modified, modifiedAt: entry.modifiedAt))
            } else {
                changes.append(Change(relativePath: relativePath, kind: .created, modifiedAt: entry.modifiedAt))
            }
        }
        for relativePath in before.entries.keys where entries[relativePath] == nil {
            changes.append(Change(relativePath: relativePath, kind: .removed, modifiedAt: nil))
        }
        return changes.sorted { $0.relativePath < $1.relativePath }
    }

    /// Walks `taskFolder` on the calling thread. Returns an empty snapshot for
    /// a folder that does not exist yet — the run may be the one to create it —
    /// and nil when the folder cannot be walked or is past `entryLimit`.
    static func scan(
        taskFolder: String,
        entryLimit: Int = entryLimit,
        fileManager: FileManager = .default
    ) -> TaskFolderRunSnapshot? {
        guard !taskFolder.isEmpty else { return nil }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(taskFolder)
        let rootURL = URL(fileURLWithPath: root.standardized, isDirectory: true)
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let intent = HostFileAccessIntent.astraManagedStorage(root: rootURL)
        var isDirectory: ObjCBool = false
        guard hostFileAccess.fileExists(at: rootURL, isDirectory: &isDirectory, intent: intent) else {
            return TaskFolderRunSnapshot(root: root, entries: [:])
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard isDirectory.boolValue,
              let enumerator = hostFileAccess.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                intent: intent
              ) else {
            return nil
        }

        var entries: [String: Entry] = [:]
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= entryLimit else { return nil }
            guard let relativePath = relativePath(of: url, under: root) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isVisible = TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relativePath,
                context: .taskFolder
            ) != nil
            if values?.isDirectory == true {
                // Prune before descending: `outputs/`, `diagnostics/`, and a
                // virtualenv are whole subtrees nobody would look at.
                if !isVisible { enumerator.skipDescendants() }
                continue
            }
            // Symlinks are skipped: what they point at is not the task's work.
            guard isVisible, values?.isRegularFile == true else { continue }
            entries[relativePath] = Entry(size: values?.fileSize ?? 0, modifiedAt: values?.contentModificationDate)
        }
        return TaskFolderRunSnapshot(root: root, entries: entries)
    }

    /// `scan` off the main actor.
    static func capture(taskFolder: String) async -> TaskFolderRunSnapshot? {
        await Task.detached(priority: .userInitiated) {
            scan(taskFolder: taskFolder)
        }.value
    }

    /// The enumerator hands back children under the root it was given, so the
    /// standardized prefix nearly always matches; the resolved one covers a
    /// root that sits behind a symlink such as `/var` → `/private/var`.
    private static func relativePath(of url: URL, under root: TaskOutputArtifactPathPolicy.ResolvedRoot) -> String? {
        let path = url.standardizedFileURL.path
        for prefix in [root.standardized, root.resolved] where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return nil
    }
}

extension TaskFolderRunSnapshot {
    @MainActor
    static func capture(for task: AgentTask) async -> TaskFolderRunSnapshot? {
        await capture(taskFolder: TaskWorkspaceAccess(task: task).taskFolder)
    }

    /// Takes the after-run snapshot of the same folder `before` walked and
    /// appends what changed to `run`. Paths the run already recorded through a
    /// tool event keep that richer record and are not repeated.
    @MainActor
    @discardableResult
    static func recordChanges(
        since before: TaskFolderRunSnapshot?,
        task: AgentTask,
        run: TaskRun,
        runStartedAt: Date
    ) async -> [StoredFileChange] {
        guard let before else {
            logSkipped(task: task, run: run, reason: "no_baseline")
            return []
        }
        let started = Date()
        guard let after = await capture(taskFolder: before.root.standardized) else {
            logSkipped(task: task, run: run, reason: "unreadable_or_over_limit")
            return []
        }
        let changes = after.changes(since: before)
        let stored = append(changes, under: after.root, to: run, runStartedAt: runStartedAt, runEndedAt: Date())
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "event": "task_folder_snapshot",
            "run_id": String(run.id.uuidString.prefix(8)),
            "files": String(after.entries.count),
            "changed": String(changes.count),
            "recorded": String(stored.count),
            "limit_reached": String(stored.count >= recordedChangeLimit),
            "duration_ms": String(Int(Date().timeIntervalSince(started) * 1_000))
        ])
        return stored
    }

    @MainActor
    static func append(
        _ changes: [Change],
        under root: TaskOutputArtifactPathPolicy.ResolvedRoot,
        to run: TaskRun,
        runStartedAt: Date,
        runEndedAt: Date,
        limit: Int = recordedChangeLimit
    ) -> [StoredFileChange] {
        guard !changes.isEmpty else { return [] }
        // Tool events carry whatever path the provider reported, which may be
        // either side of a symlinked root. A snapshot path's two spellings come
        // from its root, so only the handful of recorded paths pay a resolve.
        let alreadyRecorded = Set(run.allFileChanges.flatMap { change -> [String] in
            let url = URL(fileURLWithPath: change.path)
            return [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        })
        let window = runStartedAt...max(runStartedAt, runEndedAt)
        let unrecorded = changes.filter { change in
            !alreadyRecorded.contains(root.standardized + "/" + change.relativePath) &&
                !alreadyRecorded.contains(root.resolved + "/" + change.relativePath)
        }
        let kept = unrecorded
            .sorted { ($0.kind.recordingPriority, $0.relativePath) < ($1.kind.recordingPriority, $1.relativePath) }
            .prefix(limit)
        let stored = kept.map { change in
            StoredFileChange(
                path: root.standardized + "/" + change.relativePath,
                changeType: change.kind.storedKind.rawValue,
                timestamp: change.modifiedAt.map { $0.clamped(to: window) } ?? runEndedAt
            )
        }
        run.appendHostFileChanges(stored)
        return stored
    }

    @MainActor
    private static func logSkipped(task: AgentTask, run: TaskRun, reason: String) {
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "event": "task_folder_snapshot_skipped",
            "run_id": String(run.id.uuidString.prefix(8)),
            "reason": reason
        ])
    }
}

private extension Date {
    func clamped(to range: ClosedRange<Date>) -> Date {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
