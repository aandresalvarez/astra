import CryptoKit
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
/// Metadata is read for every file and contents only for small ones, so a
/// folder of a few hundred files costs milliseconds; the walk, the
/// comparison, and the bounding all run off the main actor. The visibility
/// rules are the Files shelf's (`TaskOutputArtifactPathPolicy`), so ASTRA's
/// own bookkeeping (`outputs/`, `inputs/`, `current_state.*`, `diagnostics/`)
/// and dependency trees never count as the run's work. Hidden files are
/// skipped, which keeps Finder's `.DS_Store` writes out of every run.
struct TaskFolderRunSnapshot: Sendable, Equatable {
    /// Size and modified time alone miss a same-length rewrite that keeps its
    /// timestamp (`cp -p`, `touch -r`). The kernel moves the status-change
    /// time on every write and an atomic replace changes the file identifier,
    /// but on a filesystem with coarse timestamps both writes can still land
    /// in one tick; the content fingerprint covers that for small files.
    struct Entry: Sendable, Equatable, Codable {
        let size: Int
        let modifiedAt: Date?
        let statusChangedAt: Date?
        let fileIdentifier: UInt64?
        /// The first 8 bytes of the content's SHA-256: the same in every
        /// launch, so a baseline persisted before a crash still compares.
        let contentFingerprint: UInt64?

        /// A fingerprint only counts when both walks took one: the byte budget
        /// can fall differently between them, and a missing fingerprint is no
        /// evidence of an edit.
        func differs(from other: Entry) -> Bool {
            if size != other.size || modifiedAt != other.modifiedAt ||
                statusChangedAt != other.statusChangedAt || fileIdentifier != other.fileIdentifier {
                return true
            }
            guard let contentFingerprint, let otherFingerprint = other.contentFingerprint else { return false }
            return contentFingerprint != otherFingerprint
        }
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

    /// Files up to this size are fingerprinted, until one walk has read
    /// `fingerprintByteBudget` bytes; anything larger relies on metadata, so
    /// a folder of data files is never read in full.
    static let fingerprintFileLimit = 256 * 1_024
    static let fingerprintByteBudget = 32 * 1_024 * 1_024

    /// Observed changes recorded on one run. A run that touches more files
    /// than this is a bulk operation nobody reviews file by file; new and
    /// edited files are kept ahead of removals. The encoded size is bounded
    /// separately, by `TaskRun.displayedFileChangesJSONByteLimit`.
    static let recordedChangeLimit = 250

    /// What observations may add to a run whose record is already past the
    /// thread's decode limit. The thread shows none of it either way, but the
    /// turns ledger reads the whole record, and a run that wrote a large file
    /// with a tool is exactly one whose shell-made changes are worth keeping.
    static let overLimitByteAllowance = 64 * 1_024

    let root: TaskOutputArtifactPathPolicy.ResolvedRoot
    /// Keyed by path relative to `root`.
    let entries: [String: Entry]

    func changes(since before: TaskFolderRunSnapshot) -> [Change] {
        var changes: [Change] = []
        for (relativePath, entry) in entries {
            if let previous = before.entries[relativePath] {
                guard previous.differs(from: entry) else { continue }
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
    /// and nil when any part of the folder cannot be walked or it is past
    /// `entryLimit`.
    static func scan(
        taskFolder: String,
        entryLimit: Int = entryLimit,
        fingerprintFileLimit: Int = fingerprintFileLimit,
        fingerprintByteBudget: Int = fingerprintByteBudget,
        fileManager: FileManager = .default,
        readValues: (URL, Set<URLResourceKey>) throws -> URLResourceValues = { try $0.resourceValues(forKeys: $1) }
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
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
            .contentModificationDateKey, .attributeModificationDateKey, .fileIdentifierKey
        ]
        let walkFailure = WalkFailure()
        guard isDirectory.boolValue,
              let enumerator = hostFileAccess.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                intent: intent,
                errorHandler: { _, _ in
                    walkFailure.occurred = true
                    return false
                }
              ) else {
            return nil
        }

        var entries: [String: Entry] = [:]
        var visited = 0
        var fingerprintBytesLeft = fingerprintByteBudget
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= entryLimit else { return nil }
            guard let relativePath = relativePath(of: url, under: root) else { continue }
            let isVisible = TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relativePath,
                context: .taskFolder
            ) != nil
            let values: URLResourceValues
            do {
                values = try readValues(url, Set(keys))
            } catch {
                // A visible file left out of one walk reads as removed, or as
                // created, against the other.
                guard isVisible else { continue }
                walkFailure.occurred = true
                break
            }
            if values.isDirectory == true {
                // Prune before descending: `outputs/`, `diagnostics/`, and a
                // virtualenv are whole subtrees nobody would look at.
                if !isVisible { enumerator.skipDescendants() }
                continue
            }
            // Symlinks are skipped: what they point at is not the task's work.
            guard isVisible, values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            var fingerprint: UInt64?
            if size <= fingerprintFileLimit, size <= fingerprintBytesLeft {
                let read = contentFingerprint(
                    of: url,
                    maxBytes: min(fingerprintFileLimit, fingerprintBytesLeft),
                    hostFileAccess: hostFileAccess,
                    intent: intent
                )
                fingerprint = read.fingerprint
                fingerprintBytesLeft -= read.bytesRead
            }
            entries[relativePath] = Entry(
                size: size,
                modifiedAt: values.contentModificationDate,
                statusChangedAt: values.attributeModificationDate,
                fileIdentifier: values.fileIdentifier,
                contentFingerprint: fingerprint
            )
        }
        // A directory the walk could not read leaves its files out, and against
        // a complete baseline every one of them would read as removed.
        guard !walkFailure.occurred else { return nil }
        return TaskFolderRunSnapshot(root: root, entries: entries)
    }

    private final class WalkFailure {
        var occurred = false
    }

    /// Reads at most `maxBytes + 1`: a file that grew or was replaced after
    /// its size was read cannot pull more than that into memory. Nil when the
    /// file cannot be read or no longer fits; the fingerprint only adds
    /// evidence, so its absence falls back to metadata.
    static func contentFingerprint(
        of url: URL,
        maxBytes: Int,
        hostFileAccess: HostFileAccessBroker = HostFileAccessBroker(),
        intent: HostFileAccessIntent
    ) -> (fingerprint: UInt64?, bytesRead: Int) {
        guard let data = try? hostFileAccess.readData(
            at: url,
            maxBytes: maxBytes + 1,
            keeping: .prefix,
            intent: intent
        ) else { return (nil, 0) }
        guard data.count <= maxBytes else { return (nil, data.count) }
        let digest = SHA256.hash(data: data)
        return (digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, data.count)
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
    /// `executionPath` is the provider's working directory, which relative
    /// tool paths are relative to.
    /// What `recordChanges` did, for `settleBaseline` once the run is saved.
    struct RecordOutcome {
        static let skipped = RecordOutcome(records: [], observed: false, baselineURL: nil)
        let records: [StoredFileChange]
        let observed: Bool
        let baselineURL: URL?
    }

    @MainActor
    @discardableResult
    static func recordChanges(
        since before: TaskFolderRunSnapshot?,
        task: AgentTask,
        run: TaskRun,
        runStartedAt: Date,
        executionPath: String
    ) async -> RecordOutcome {
        guard let before else {
            logSkipped(task: task, run: run, reason: "no_baseline")
            return .skipped
        }
        let started = Date()
        let recordedJSON = run.fileChangesJSON
        let baselineURL = baselineURL(taskFolder: before.root.standardized, runID: run.id)
        // A bulk run can leave tens of thousands of entries to compare and
        // sort, so only the bounded result comes back to the main actor.
        let outcome = await Task.detached(priority: .userInitiated, operation: {
            observe(
                since: before,
                recordedJSON: recordedJSON,
                executionPath: executionPath,
                runStartedAt: runStartedAt,
                runEndedAt: started
            )
        }).value
        let observation: Observation
        switch outcome {
        case .success(let observed):
            observation = observed
        case .failure(let skip):
            logSkipped(task: task, run: run, reason: skip.rawValue)
            return RecordOutcome(records: [], observed: false, baselineURL: baselineURL)
        }
        run.appendHostFileChanges(observation.records)
        logObservation(observation, task: task, run: run, started: started)
        return RecordOutcome(records: observation.records, observed: true, baselineURL: baselineURL)
    }

    @MainActor
    static func logObservation(
        _ observation: Observation,
        task: AgentTask,
        run: TaskRun,
        started: Date,
        recovered: Bool = false
    ) {
        var fields = [
            "event": "task_folder_snapshot",
            "run_id": String(run.id.uuidString.prefix(8)),
            "files": String(observation.fileCount),
            "changed": String(observation.changeCount),
            "recorded": String(observation.records.count),
            // Files the run's tools wrote that were gone again by its end.
            "inferred_removed": String(observation.inferredRemovalCount),
            // Detected changes the count or byte bound left out of the record.
            "omitted": String(observation.omittedCount),
            "limit_reached": String(observation.omittedCount > 0),
            "duration_ms": String(Int(Date().timeIntervalSince(started) * 1_000))
        ]
        if recovered { fields["recovered"] = "true" }
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: fields)
    }

    struct Observation: Sendable {
        let fileCount: Int
        let changeCount: Int
        let records: [StoredFileChange]
        let omittedCount: Int
        let inferredRemovalCount: Int
    }

    /// Records to append, and how many new observations the bounds left out.
    struct BoundedRecords: Sendable {
        let records: [StoredFileChange]
        let omitted: Int
    }

    enum ObservationSkip: String, Error {
        case unreadableOrOverLimit = "unreadable_or_over_limit"
        case undecodableRecord = "undecodable_file_changes"
        case unreadableBaseline = "unreadable_baseline"
    }

    /// The after-run walk and the records it yields, on the calling thread.
    /// `recordedJSON` is the run's `fileChangesJSON` as the process left it.
    static func observe(
        since before: TaskFolderRunSnapshot,
        recordedJSON: String,
        executionPath: String,
        runStartedAt: Date,
        runEndedAt: Date
    ) -> Result<Observation, ObservationSkip> {
        // Appending to a record that cannot be read would replace it, tool
        // changes and all, with only the observations.
        guard case .success(let recorded) = TaskRun.decodedFileChanges(from: recordedJSON) else {
            return .failure(.undecodableRecord)
        }
        guard let after = scan(taskFolder: before.root.standardized) else { return .failure(.unreadableOrOverLimit) }
        let removedWrites = removalsOfWrittenFiles(recorded, before: before, after: after, executionPath: executionPath)
        let changes = after.changes(since: before) + removedWrites
        let bounded = records(
            for: changes,
            under: after.root,
            recorded: recorded,
            usedBytes: recordedJSON.utf8.count,
            executionPath: executionPath,
            runStartedAt: runStartedAt,
            runEndedAt: runEndedAt
        )
        return .success(Observation(
            fileCount: after.entries.count,
            changeCount: changes.count,
            records: bounded.records,
            omittedCount: bounded.omitted,
            inferredRemovalCount: removedWrites.count
        ))
    }

    /// Removals neither walk can see: files this run's tools wrote that
    /// neither walk found and nothing occupies now, so the run created and
    /// deleted them. A tool's write proves the file existed because the
    /// recorder keeps it only once the call's result succeeded, or after a
    /// clean exit with no failure reported. Requiring an empty path, not only
    /// absence from the walks, keeps a hidden file, a symlink, or anything
    /// else the walk skips from reading as removed.
    static func removalsOfWrittenFiles(
        _ recorded: [StoredFileChange],
        before: TaskFolderRunSnapshot,
        after: TaskFolderRunSnapshot,
        executionPath: String
    ) -> [Change] {
        var removed = Set<String>()
        for change in recorded where change.kind == .write || change.kind == .edit {
            let underRoot = spellings(of: change.path, relativeTo: executionPath).lazy.compactMap {
                relativePath(of: URL(fileURLWithPath: $0), under: after.root)
            }
            guard let relativePath = underRoot.first,
                  isListedByWalk(relativePath),
                  before.entries[relativePath] == nil, after.entries[relativePath] == nil,
                  (try? FileManager.default.attributesOfItem(atPath: after.root.standardized + "/" + relativePath)) == nil
            else { continue }
            removed.insert(relativePath)
        }
        return removed.sorted().map { Change(relativePath: $0, kind: .removed, modifiedAt: nil) }
    }

    /// A path the walk lists when a file is there: one the Files shelf shows,
    /// outside any hidden file or folder, which the walk skips.
    private static func isListedByWalk(_ relativePath: String) -> Bool {
        isWalkablePath(relativePath) && !relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    @MainActor
    static func append(
        _ changes: [Change],
        under root: TaskOutputArtifactPathPolicy.ResolvedRoot,
        to run: TaskRun,
        executionPath: String,
        runStartedAt: Date,
        runEndedAt: Date,
        limit: Int = recordedChangeLimit
    ) -> [StoredFileChange] {
        let stored = records(
            for: changes,
            under: root,
            recorded: run.allFileChanges,
            usedBytes: run.fileChangesJSON.utf8.count,
            executionPath: executionPath,
            runStartedAt: runStartedAt,
            runEndedAt: runEndedAt,
            limit: limit
        ).records
        run.appendHostFileChanges(stored)
        return stored
    }

    /// The changes worth appending to a run that has already `recorded`
    /// changes taking `usedBytes` of JSON: not already recorded, new and
    /// edited files first, and bounded by count and by encoded size — up to
    /// the thread's decode limit, or by `overLimitByteAllowance` for a record
    /// already past it.
    static func records(
        for changes: [Change],
        under root: TaskOutputArtifactPathPolicy.ResolvedRoot,
        recorded: [StoredFileChange],
        usedBytes: Int,
        executionPath: String,
        runStartedAt: Date,
        runEndedAt: Date,
        limit: Int = recordedChangeLimit
    ) -> BoundedRecords {
        guard !changes.isEmpty else { return BoundedRecords(records: [], omitted: 0) }
        // Only the already-recorded paths pay a resolve; a snapshot path's two
        // spellings come from its root.
        var recordedPaths = Set<String>()
        var recordedRemovals = Set<String>()
        for change in recorded {
            let forms = spellings(of: change.path, relativeTo: executionPath)
            recordedPaths.formUnion(forms)
            if change.kind == .removed { recordedRemovals.formUnion(forms) }
        }
        let unrecorded = changes.filter { change in
            // A tool edit cannot stand for a later deletion of the same file,
            // so a removal is only a repeat of an earlier removal.
            let recorded = change.kind == .removed ? recordedRemovals : recordedPaths
            return !recorded.contains(root.standardized + "/" + change.relativePath) &&
                !recorded.contains(root.resolved + "/" + change.relativePath)
        }
        let window = runStartedAt...max(runStartedAt, runEndedAt)
        // Past the thread's decode limit the whole array stops showing, the
        // tool changes with it, so a record under it stays under it.
        var byteBudget = usedBytes <= TaskRun.displayedFileChangesJSONByteLimit
            ? TaskRun.displayedFileChangesJSONByteLimit - usedBytes
            : overLimitByteAllowance
        var stored: [StoredFileChange] = []
        for change in unrecorded
            .sorted(by: { ($0.kind.recordingPriority, $0.relativePath) < ($1.kind.recordingPriority, $1.relativePath) }) {
            // The count is of records kept, so a skipped long path frees its
            // slot for the next one.
            guard stored.count < limit else { break }
            let record = StoredFileChange(
                path: root.standardized + "/" + change.relativePath,
                changeType: change.kind.storedKind.rawValue,
                timestamp: change.modifiedAt.map { $0.clamped(to: window) } ?? runEndedAt
            )
            // The array encodes each element exactly as alone, plus a comma.
            // One long path that does not fit leaves room for shorter ones.
            let size = TaskEvent.payloadString(record).utf8.count + 1
            guard size <= byteBudget else { continue }
            byteBudget -= size
            stored.append(record)
        }
        return BoundedRecords(records: stored, omitted: unrecorded.count - stored.count)
    }

    /// A tool event carries whatever path the provider reported: relative to
    /// its working directory, or absolute on either side of a symlink.
    private static func spellings(of path: String, relativeTo executionPath: String) -> [String] {
        let url = path.hasPrefix("/") || executionPath.isEmpty
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: executionPath, isDirectory: true).appendingPathComponent(path)
        return [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
    }

    @MainActor
    static func logSkipped(task: AgentTask, run: TaskRun, reason: String, recovered: Bool = false) {
        var fields = [
            "event": "task_folder_snapshot_skipped",
            "run_id": String(run.id.uuidString.prefix(8)),
            "reason": reason
        ]
        if recovered { fields["recovered"] = "true" }
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: fields)
    }
}

private extension Date {
    func clamped(to range: ClosedRange<Date>) -> Date {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
