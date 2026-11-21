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
        for checkout in TaskWorkspaceAccess(task: task).replacedSourceCheckoutPaths {
            if let snapshot = await snapshot(of: checkout) { snapshots.append(snapshot) }
        }
        return snapshots
    }

    static func snapshot(of checkout: String) async -> Snapshot? {
        guard GitCheckoutLayout.worktreeRoot(containing: checkout) != nil else { return nil }
        let status = await AgentFileChangeDetector.gitStatusSnapshot(workspacePath: checkout)
        let head = await head(of: checkout)
        let dirtyContent = await BlockingWork.run { content(of: status, in: checkout) }
        return Snapshot(checkout: checkout, head: head, status: status, dirtyContent: dirtyContent)
    }

    /// A deleted file and a folder Git lists as untracked have no entry: they
    /// are compared by their status line alone, so a change inside such a
    /// folder is not seen. A file over the detector's size limit is compared
    /// by size and time.
    private static func content(of status: Set<String>, in checkout: String) -> [String: AgentFileChangeDetector.FileFingerprint] {
        var content: [String: AgentFileChangeDetector.FileFingerprint] = [:]
        for line in status {
            guard let path = AgentFileChangeDetector.absolutePaths(fromGitStatus: [line], workspacePath: checkout).first else { continue }
            content[line] = AgentFileChangeDetector.fileFingerprints(for: [path], workspacePath: checkout)[path]
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
            let stillNamed = AgentFileChangeDetector.absolutePaths(fromGitStatus: now.status, workspacePath: earlier.checkout)
            let disappeared = earlier.status.subtracting(now.status).filter { line in
                AgentFileChangeDetector.absolutePaths(fromGitStatus: [line], workspacePath: earlier.checkout).isDisjoint(with: stillNamed)
            }.sorted()
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

    /// `git rev-parse HEAD`, waited on by a dispatch worker like the status
    /// snapshot beside it, never by the main actor.
    private static func head(of checkout: String) async -> String {
        await BlockingWork.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", checkout, "rev-parse", "HEAD"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return "" }
                return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { return "" }
        }
    }
}
