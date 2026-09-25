import Foundation
import ASTRAModels
import ASTRAPersistence

/// What one request did to the task's files.
///
/// A turn is the Nth thing the user asked, with the task's goal as turn 1. A
/// run belongs to the message it was launched for; a run with no such link (a
/// retry, a plan step, a scheduled run) belongs to the latest request before
/// it started, which keeps it in the turn it was serving.
struct TaskFileTurn: Identifiable, Equatable, Sendable {
    enum Change: Int, CaseIterable, Comparable, Sendable {
        case new
        case edited
        case removed

        static func < (lhs: Change, rhs: Change) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        /// Relative to the folder that holds it: the task folder, the
        /// workspace, or one of the workspace's other folders.
        let pathInRoot: String
        /// That folder's name, for a file outside the task folder and the
        /// workspace folder.
        var rootName: String?
        let change: Change
        let changedAt: Date
        /// False for a removed file, and for one a later turn removed.
        let exists: Bool

        var displayPath: String {
            rootName.map { "\($0)/\(pathInRoot)" } ?? pathInRoot
        }
    }

    var id: Int { number }
    let number: Int
    let request: String
    let requestedAt: Date
    let isRunning: Bool
    /// Changed files, new ones first.
    let entries: [Entry]
    /// Some files came from the artifact index rather than the run's own
    /// record: runs before ASTRA compared the task folder around every run
    /// recorded only the files a tool wrote, so the index can say which files
    /// appeared, but not which were edited or removed.
    let listsNewFilesOnly: Bool
}

/// Everything `TaskFileTurns.build` reads, as plain values off the store.
struct TaskFileTurnsInput: Sendable {
    struct Request: Sendable {
        let text: String
        let requestedAt: Date
        /// The run this message launched, when the runtime linked one.
        let runID: UUID?
        /// A plan-created task records the user's ask as a plan message.
        var isPlanMessage = false
    }

    struct Change: Sendable {
        let path: String
        let kind: StoredFileChangeKind
        let timestamp: Date
    }

    struct Run: Sendable {
        let id: UUID
        let startedAt: Date
        let completedAt: Date?
        let isRunning: Bool
        let changes: [Change]
    }

    /// When the artifact index first saw a path.
    struct IndexedFile: Sendable {
        let path: String
        let indexedAt: Date
    }

    let goal: String
    let createdAt: Date
    /// Follow-up requests, in any order. The goal is added as turn 1.
    let requests: [Request]
    let runs: [Run]
    let indexedFiles: [IndexedFile]
    let taskFolder: String
    /// The task's workspace folder.
    let workspacePath: String
    /// Where the task's runs execute when that is not the workspace folder:
    /// the repository or worktree it is pinned to. Relative tool paths
    /// resolve against it first, and its files are listed with its name.
    var executionPath: String?
    /// The folders of the tasks this one was forked from, nearest first. A
    /// fork copies its source's runs as they were, so their paths name those
    /// folders, and a file there that no fork copied is one it shares.
    var inheritedTaskFolders: [String] = []
    /// What each fork in the chain copied, source path to copy, the fork
    /// nearest the first task first: a copied file opens from its copy, as
    /// the Files shelf opens it.
    var forkCopies: [[String: String]] = []
    /// The workspace's other folders the Files shelf browses.
    var additionalRoots: [String] = []
}

enum TaskFileTurns {
    /// Finalization indexes a run's new outputs just after it sets
    /// `completedAt`; in production every such row lands within 5 seconds.
    static let indexingGrace: TimeInterval = 10

    /// Turns that changed at least one file, plus a running one, newest first.
    static func build(
        _ input: TaskFileTurnsInput,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [TaskFileTurn] {
        // A plan-created task already holds its goal as a plan message; the
        // thread shows the ask once, and it is one turn here too.
        let trimmedGoal = input.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalIsARequest = input.requests.contains {
            $0.isPlanMessage && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedGoal
        }
        let goal = TaskFileTurnsInput.Request(text: input.goal, requestedAt: input.createdAt, runID: nil)
        let requests = (goalIsARequest ? [] : [goal]) + input.requests.sorted { $0.requestedAt < $1.requestedAt }
        let runs = input.runs.sorted { $0.startedAt < $1.startedAt }
        let runsByTurn = Dictionary(grouping: runs) { turnIndex(for: $0, in: requests) }
        let paths = PathClassifier(
            taskFolder: input.taskFolder,
            inheritedTaskFolders: input.inheritedTaskFolders,
            workspacePath: input.workspacePath,
            executionPath: input.executionPath,
            additionalRoots: input.additionalRoots,
            forkCopies: input.forkCopies
        )
        let indexedByRun = indexedFilesWithoutARunRecord(input.indexedFiles, runs: runs, paths: paths)

        var touchedBefore = Set<String>()
        var turns: [TaskFileTurn] = []
        for (index, request) in requests.enumerated() {
            var history = TurnHistory()
            var listsNewFilesOnly = false
            let turnRuns = runsByTurn[index] ?? []
            for run in turnRuns {
                for change in run.changes {
                    guard let file = paths.classify(change.path) else { continue }
                    let wasTouched = touchedBefore.contains(file.key) || history.contains(file.key)
                    history.record(file, step: Step(change.kind, wasTouched: wasTouched), at: change.timestamp)
                }
                for indexed in indexedByRun[run.id] ?? [] {
                    guard let file = paths.classify(indexed.path) else { continue }
                    history.record(file, step: .created, at: indexed.indexedAt)
                    listsNewFilesOnly = true
                }
            }
            touchedBefore.formUnion(history.keys)
            let isRunning = turnRuns.contains(where: \.isRunning)
            let entries = history.entries(fileExists: fileExists)
            guard !entries.isEmpty || isRunning else { continue }
            turns.append(TaskFileTurn(
                number: index + 1,
                request: request.text,
                requestedAt: request.requestedAt,
                isRunning: isRunning,
                entries: entries,
                listsNewFilesOnly: listsNewFilesOnly
            ))
        }
        return turns.reversed()
    }

    private static func turnIndex(for run: TaskFileTurnsInput.Run, in requests: [TaskFileTurnsInput.Request]) -> Int {
        if let linked = requests.firstIndex(where: { $0.runID == run.id }) {
            return linked
        }
        return requests.lastIndex { $0.requestedAt <= run.startedAt } ?? 0
    }

    /// Files the index saw appear with no run record of that appearance, each
    /// given to the run it appeared during or just after. A run record of the
    /// path from that run or an earlier one already covers it; one from a
    /// later run does not, since that run only edited or removed what an
    /// earlier turn made.
    private static func indexedFilesWithoutARunRecord(
        _ indexedFiles: [TaskFileTurnsInput.IndexedFile],
        runs: [TaskFileTurnsInput.Run],
        paths: PathClassifier
    ) -> [UUID: [TaskFileTurnsInput.IndexedFile]] {
        var firstRecordedAt: [String: Date] = [:]
        for run in runs {
            for change in run.changes {
                guard let key = paths.classify(change.path)?.key else { continue }
                firstRecordedAt[key] = min(firstRecordedAt[key] ?? run.startedAt, run.startedAt)
            }
        }
        var firstIndexed: [String: (key: String, file: TaskFileTurnsInput.IndexedFile)] = [:]
        for file in indexedFiles {
            guard let key = paths.classify(file.path)?.key else { continue }
            if let existing = firstIndexed[key], existing.file.indexedAt <= file.indexedAt { continue }
            firstIndexed[key] = (key, file)
        }
        var byRun: [UUID: [TaskFileTurnsInput.IndexedFile]] = [:]
        for (key, file) in firstIndexed.values {
            guard let run = runs.last(where: { $0.startedAt <= file.indexedAt }),
                  file.indexedAt <= (run.completedAt ?? .distantFuture).addingTimeInterval(indexingGrace) else {
                continue
            }
            if let recordedAt = firstRecordedAt[key], recordedAt <= run.startedAt { continue }
            byRun[run.id, default: []].append(file)
        }
        return byRun
    }

    private enum Step {
        case created
        case edited
        case removed

        init(_ kind: StoredFileChangeKind, wasTouched: Bool) {
            switch kind {
            case .discovered:
                self = .created
            case .write:
                // A tool write replaces the whole file, so it reads as new only
                // the first time the task sees the path.
                self = wasTouched ? .edited : .created
            case .edit, .modified, .unknown:
                self = .edited
            case .removed:
                self = .removed
            }
        }
    }

    private struct TurnHistory {
        private struct Path {
            let file: ClassifiedPath
            var first: Step
            var last: Step
            var changedAt: Date
        }

        private var paths: [String: Path] = [:]

        var keys: [String] { Array(paths.keys) }

        func contains(_ key: String) -> Bool { paths[key] != nil }

        mutating func record(_ file: ClassifiedPath, step: Step, at date: Date) {
            if var existing = paths[file.key] {
                existing.last = step
                existing.changedAt = max(existing.changedAt, date)
                paths[file.key] = existing
            } else {
                paths[file.key] = Path(file: file, first: step, last: step, changedAt: date)
            }
        }

        func entries(fileExists: (String) -> Bool) -> [TaskFileTurn.Entry] {
            paths.values.compactMap { path -> TaskFileTurn.Entry? in
                let change: TaskFileTurn.Change
                switch (path.first, path.last) {
                case (.created, .removed):
                    return nil // Made and discarded inside the turn: nothing to show.
                case (_, .removed):
                    change = .removed
                case (.created, _):
                    change = .new
                default:
                    change = .edited
                }
                return TaskFileTurn.Entry(
                    path: path.file.path,
                    pathInRoot: path.file.pathInRoot,
                    rootName: path.file.rootName,
                    change: change,
                    changedAt: path.changedAt,
                    exists: change != .removed && fileExists(path.file.path)
                )
            }
            .sorted {
                if $0.change != $1.change { return $0.change < $1.change }
                return $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
            }
        }
    }

    fileprivate struct ClassifiedPath {
        /// One spelling per file, whichever side of a symlink a provider
        /// reported it from.
        let key: String
        let path: String
        let pathInRoot: String
        let rootName: String?
    }

    /// Keeps the files a user would browse — under the task folder or the
    /// workspace, by the Files shelf's rules — and names each relative to the
    /// folder that holds it.
    private final class PathClassifier {
        private struct Root {
            let root: TaskOutputArtifactPathPolicy.ResolvedRoot
            let context: TaskOutputArtifactPathPolicy.RelativePathContext
            let keyPrefix: String
            let rootName: String?
        }

        private let taskFolderPath: String
        private let forkCopies: [[String: String]]
        /// What a relative path is resolved against, in order: where the task
        /// runs, then the workspace folder, which older runs ran in.
        private let resolutionBases: [String]
        private let roots: [Root]
        private var cache: [String: ClassifiedPath?] = [:]

        init(
            taskFolder: String,
            inheritedTaskFolders: [String],
            workspacePath: String,
            executionPath: String?,
            additionalRoots: [String],
            forkCopies: [[String: String]]
        ) {
            self.taskFolderPath = taskFolder
            self.forkCopies = forkCopies
            let executionPath = executionPath.flatMap { $0.isEmpty || $0 == workspacePath ? nil : $0 }
            self.resolutionBases = [executionPath, workspacePath].compactMap { $0 }
            let workspace = TaskOutputArtifactPathPolicy.ResolvedRoot(workspacePath)
            // The task folders sit inside the workspace, so they are tried
            // first. A source task's file is a different file from this
            // task's at the same relative path.
            var roots = [Root(root: .init(taskFolder), context: .taskFolder, keyPrefix: "task", rootName: nil)]
            roots += inheritedTaskFolders.map {
                let root = TaskOutputArtifactPathPolicy.ResolvedRoot($0)
                return Root(root: root, context: .taskFolder, keyPrefix: "task@\(root.standardized)", rootName: nil)
            }
            roots.append(Root(root: workspace, context: .workspace, keyPrefix: "workspace", rootName: nil))
            var added: Set<String> = [workspace.standardized]
            for path in additionalRoots + [executionPath].compactMap({ $0 }) {
                let root = TaskOutputArtifactPathPolicy.ResolvedRoot(path)
                guard added.insert(root.standardized).inserted else { continue }
                roots.append(Root(
                    root: root,
                    context: .workspace,
                    keyPrefix: "root:\(root.standardized)",
                    rootName: (root.standardized as NSString).lastPathComponent
                ))
            }
            self.roots = roots.filter { !$0.root.isEmpty }
        }

        func classify(_ path: String) -> ClassifiedPath? {
            if let cached = cache[path] { return cached }
            let classified = uncachedClassify(path)
            cache[path] = classified
            return classified
        }

        private func uncachedClassify(_ path: String) -> ClassifiedPath? {
            // Providers record some paths relative to where they ran, and
            // `URL(fileURLWithPath:)` would resolve those against the app's
            // own working directory instead.
            let isAbsolute = path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            for base in isAbsolute ? [""] : resolutionBases {
                let absolute = TaskArtifactPathNormalizer.normalizedPath(
                    path,
                    workspacePath: base,
                    taskFolder: taskFolderPath
                )
                if let classified = classify(absolute: absolute) { return classified }
            }
            return nil
        }

        private func classify(absolute: String) -> ClassifiedPath? {
            guard absolute.hasPrefix("/") else { return nil }
            var standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
            // Oldest fork first, so a copy of a copy lands on the newest one.
            for copies in forkCopies {
                if let copy = copies[standardized] { standardized = copy }
            }
            for root in roots {
                guard let relative = TaskOutputArtifactPathPolicy.relativePath(standardized, under: root.root) else {
                    continue
                }
                guard let visible = TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                    relative,
                    context: root.context
                ) else { return nil }
                return ClassifiedPath(
                    key: "\(root.keyPrefix):\(visible)",
                    path: root.root.standardized + "/" + visible,
                    pathInRoot: visible,
                    rootName: root.rootName
                )
            }
            // A temporary file, a sibling workspace, anything else on the
            // host: not a file Browse files would list.
            return nil
        }
    }
}
