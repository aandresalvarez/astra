import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// With sandboxing Off nothing keeps a worktree task out of the checkout its
/// worktree replaced. Sibling worktree tasks still run together: ASTRA looks
/// at that checkout before and after the run and records what changed there.
/// It reverts nothing. The checkout is a Git working tree, and Git is the undo.
/// For a file that was already changed there before the run, Git has no copy
/// of what the run overwrote, so that case is named separately.
///
/// The record says the checkout changed while the run worked, not that the run
/// changed it: a person editing there at the same time looks the same. No
/// other ASTRA task can be the cause, because the worktree task holds that
/// checkout as a reader for the whole run
/// (`TaskExecutionResourceAdmissionPolicy.watchedKeys`).
enum TaskWorktreeSourceCheckoutWatch {
    struct Snapshot: Equatable, Sendable {
        let checkout: String
        /// The root of the checkout that contains it. Git names files from there.
        let root: String
        /// Empty when Git could not say.
        let head: String
        let status: Set<String>
        /// The content of each regular file `status` names, by its status
        /// line, so a second write to a file that was already dirty is seen.
        let dirtyContent: [String: AgentFileChangeDetector.FileFingerprint]
    }

    struct Change: Codable, Equatable, Sendable {
        static let reportLimit = 20
        let checkout: String
        let headBefore: String
        let headAfter: String
        /// `git status --porcelain` lines present after the run and not before, capped at `reportLimit`.
        let appeared: [String]
        let appearedCount: Int
        /// Lines present before and after whose file has different content now, capped the same way.
        let rewritten: [String]
        let rewrittenCount: Int
        /// Lines present before the run and gone now, for a path no line names any more, capped the same way.
        let disappeared: [String]
        let disappearedCount: Int
    }

    /// One snapshot per source checkout the task's worktree replaced. Empty
    /// unless the run was admitted with sandboxing Off, the same value that
    /// decided its claims: a sandbox that keeps the checkout read-only leaves
    /// nothing to watch.
    @MainActor
    static func capture(for task: AgentTask, sandboxEnforcement: ExecutionSandboxEnforcement?) async -> [Snapshot] {
        guard sandboxEnforcement == .off else { return [] }
        var snapshots: [Snapshot] = []
        for checkout in outermost(TaskWorkspaceAccess(task: task).replacedSourceCheckoutPaths) {
            if let snapshot = await snapshot(of: checkout) { snapshots.append(snapshot) }
        }
        return snapshots
    }

    /// A folder inside another watched folder is already covered by it, and
    /// would report the same files a second time.
    static func outermost(_ folders: [String]) -> [String] {
        folders.filter { folder in
            !folders.contains { $0 != folder && folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    /// Nil when the folder is not in a checkout or Git could not answer: a
    /// failed question is not a clean checkout, and is never compared.
    static func snapshot(of checkout: String) async -> Snapshot? {
        guard let root = GitCheckoutLayout.worktreeRoot(containing: checkout),
              let status = await status(of: checkout) else { return nil }
        let head = await head(of: checkout)
        let dirtyContent = await BlockingWork.run { content(of: status, under: root) }
        return Snapshot(checkout: checkout, root: root, head: head, status: status, dirtyContent: dirtyContent)
    }

    /// `git status` for the watched folder only. `-z` gives each name as it
    /// is on disk, neither quoted nor escaped, so the lines keep the usual
    /// two status letters, a space and the name from the checkout's root.
    private static func status(of checkout: String) async -> Set<String>? {
        guard let output = await git(["status", "--porcelain", "-z", "--", "."], in: checkout) else { return nil }
        var lines: Set<String> = []
        var isOrigin = false
        for entry in String(decoding: output, as: UTF8.self).split(separator: "\0") {
            // A rename or a copy is followed by the name it came from.
            if isOrigin { isOrigin = false; continue }
            lines.insert(String(entry))
            isOrigin = entry.prefix(2).contains { $0 == "R" || $0 == "C" }
        }
        return lines
    }

    /// The file a status line names.
    private static func path(of line: String, under root: String) -> String {
        (root as NSString).appendingPathComponent(String(line.dropFirst(3)))
    }

    /// A deleted file and a folder Git lists as untracked have no entry: they
    /// are compared by their status line alone, so a change inside such a
    /// folder is not seen. A file over the detector's size limit is compared
    /// by size and time.
    private static func content(of status: Set<String>, under root: String) -> [String: AgentFileChangeDetector.FileFingerprint] {
        var content: [String: AgentFileChangeDetector.FileFingerprint] = [:]
        for line in status {
            let path = path(of: line, under: root)
            content[line] = AgentFileChangeDetector.fileFingerprints(for: [path], workspacePath: root)[path]
        }
        return content
    }

    /// Rewriting a file with the bytes it already had is not a change.
    private static func differs(_ before: AgentFileChangeDetector.FileFingerprint, _ after: AgentFileChangeDetector.FileFingerprint) -> Bool {
        guard let was = before.checksum, let now = after.checksum else { return before != after }
        return before.size != after.size || was != now
    }

    /// What differs now from each earlier snapshot. A checkout Git can no
    /// longer read is not reported: an unreadable answer is not a change.
    static func changes(since before: [Snapshot]) async -> [Change] {
        var changes: [Change] = []
        for earlier in before {
            guard let now = await snapshot(of: earlier.checkout) else { continue }
            let appeared = now.status.subtracting(earlier.status).sorted()
            // A line both snapshots have names a file that was dirty all along.
            let rewritten = now.status.intersection(earlier.status).filter { line in
                guard let was = earlier.dirtyContent[line], let isNow = now.dirtyContent[line] else { return false }
                return differs(was, isNow)
            }.sorted()
            // A path that only changed its status code is already in `appeared`.
            let stillNamed = Set(now.status.map { path(of: $0, under: now.root) })
            let disappeared = earlier.status.subtracting(now.status)
                .filter { !stillNamed.contains(path(of: $0, under: earlier.root)) }.sorted()
            let headMoved = !earlier.head.isEmpty && !now.head.isEmpty && earlier.head != now.head
            guard headMoved || !appeared.isEmpty || !rewritten.isEmpty || !disappeared.isEmpty else { continue }
            let limit = Change.reportLimit
            changes.append(Change(checkout: earlier.checkout, headBefore: earlier.head, headAfter: now.head,
                appeared: Array(appeared.prefix(limit)), appearedCount: appeared.count,
                rewritten: Array(rewritten.prefix(limit)), rewrittenCount: rewritten.count,
                disappeared: Array(disappeared.prefix(limit)), disappearedCount: disappeared.count))
        }
        return changes
    }

    /// Records what changed as a durable event and a line the person can read.
    /// The worker's own save persists both with the run.
    @MainActor
    static func record(since before: [Snapshot], task: AgentTask, run: TaskRun, modelContext: ModelContext) async {
        guard !before.isEmpty else { return }
        let changes = await changes(since: before)
        guard !changes.isEmpty, task.isLive, run.isLive else { return }
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.worktreeSourceChanged,
            payload: TaskEvent.payloadString(changes, fallback: "[]"), run: run))
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
            payload: changes.map(message).joined(separator: "\n"), run: run))
        for change in changes {
            AppLogger.audit(.taskWorktreeSourceChanged, category: "Worker", taskID: task.id, fields: [
                "run_id": run.id.uuidString,
                "checkout": change.checkout,
                "head_moved": change.headBefore == change.headAfter ? "false" : "true",
                "appeared": String(change.appearedCount),
                "rewritten": String(change.rewrittenCount),
                "disappeared": String(change.disappearedCount)
            ], level: .warning)
        }
    }

    static func message(_ change: Change) -> String {
        let name = (change.checkout as NSString).lastPathComponent
        var parts: [String] = []
        if change.headBefore != change.headAfter, !change.headBefore.isEmpty, !change.headAfter.isEmpty {
            parts.append("its commit moved from \(change.headBefore.prefix(8)) to \(change.headAfter.prefix(8))")
        }
        func list(_ label: String, _ lines: [String], _ count: Int) {
            guard count > 0 else { return }
            let shown = lines.prefix(5).map { String($0.dropFirst(3)) }
            let more = count - shown.count
            parts.append(label + shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : ""))
        }
        list("new or modified there: ", change.appeared, change.appearedCount)
        list("already changed before the run and changed again: ", change.rewritten, change.rewrittenCount)
        list("changed before the run and no longer listed as changed (restored, deleted or committed): ",
             change.disappeared, change.disappearedCount)
        return "The checkout this task's worktree came from, \(name), changed while this run worked: "
            + parts.joined(separator: "; ")
            + ". This run was expected to change only its worktree. ASTRA reverted nothing; review \(change.checkout) with Git."
    }

    private static func head(of checkout: String) async -> String {
        await git(["rev-parse", "HEAD"], in: checkout)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// What Git prints for one question, waited on by a dispatch worker,
    /// never by the main actor. Nil when Git could not run or reported failure.
    private static func git(_ arguments: [String], in checkout: String) async -> Data? {
        await BlockingWork.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", checkout] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Drain while Git runs. Waiting first deadlocks when the
                // output fills the pipe on a checkout with many changed files.
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return process.terminationStatus == 0 ? output : nil
            } catch { return nil }
        }
    }
}
