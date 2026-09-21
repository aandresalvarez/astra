import Foundation
import ASTRACore
import ASTRAModels

/// Refresh entry points for `TaskContextStateManager`.
///
/// Kept beside the manager rather than inside it: that file is at its
/// line-budget ceiling, and these are the two callers' doorways into it rather
/// than part of its core.
extension TaskContextStateManager {
    /// What the off-actor half of a refresh produces.
    private struct LoadedContextState: Sendable {
        let folder: String
        let existing: TaskContextState?
        /// Identity of `current_state.json` as the read finished, so the main
        /// actor can tell whether anything wrote it since.
        let stamp: FileStamp?
        /// The file changed identity *during* the read, so `existing` and
        /// `stamp` may describe different versions and neither can be trusted.
        let readStraddledAWrite: Bool
        /// Whether the load came back in a state this path can use. Anything
        /// else has to be handled on the actor, because recovering from it
        /// writes.
        let loadWasUsable: Bool
    }

    /// Cheap identity of a file: enough to detect that someone replaced it,
    /// without re-reading and re-decoding the thing we went off-actor to avoid.
    ///
    /// The inode is what makes this exact rather than probable. `saveState`
    /// writes with `.atomic`, which renames a fresh file over the target, so
    /// every write lands a new one. Modification date and size alone can
    /// collide: a volume with coarse timestamp resolution buckets two writes
    /// together, and at the turn cap `recordTurn` drops one turn while
    /// appending another, which can encode to exactly the same length. Both
    /// halves of the bracket would then report no change and the older
    /// snapshot would go back over the newer turn.
    ///
    /// Untested: I could not build a case that distinguishes this from the
    /// previous stamp. Forcing a same-size replacement back to the same
    /// timestamp still came out correct without the inode, for a reason the
    /// stamps themselves do not explain, so any test I wrote would have passed
    /// either way. The inode is kept on the argument above and because it is
    /// free — the same `attributesOfItem` call already fetches it.
    private struct FileStamp: Equatable, Sendable {
        let modified: Date
        let size: Int
        let inode: UInt64

        init?(atPath path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int,
                  let inode = attributes[.systemFileNumber] as? UInt64 else { return nil }
            self.modified = modified
            self.size = size
            self.inode = inode
        }
    }

    private static func statePath(inFolder folder: String) -> String {
        URL(fileURLWithPath: folder).appendingPathComponent(jsonFileName).path
    }

    /// `refresh(task:)` with its state-file work moved off the main actor.
    ///
    /// `refresh` resolves the task folder — which runs a legacy-layout
    /// migration check and creates two directories — and then reads and
    /// decodes `current_state.json`, before it touches any model state. On
    /// task open that ran on the main thread: production samples of the
    /// `context_state_refresh` phase put it at p50 60 ms, p90 178 ms, max
    /// 706 ms, all attributed to `source=task_selection`.
    ///
    /// Both steps are pure functions of a workspace path and a task id, so
    /// they move off-actor. Everything that reads the SwiftData model stays on
    /// the main actor in `applyRefresh`, and so does the save, leaving
    /// durability ordering untouched — the common task-open case is a no-op
    /// refresh that never saves at all.
    ///
    /// **The output-folder scan deliberately does not move.** It did, and five
    /// rounds of review went into the consequences. Off the actor its result
    /// can go stale between the scan and the apply, and every way of closing
    /// that costs what the scan cost: validating on the actor is one
    /// `attributesOfItem` per traversed directory, which freezes selection on
    /// any large output tree exactly as the scan did; validating off the actor
    /// is itself stale by the hop it takes; and recovering by rescanning under
    /// the actor restores the freeze for precisely the busy tasks the move was
    /// meant to help. The scan stays in `updateDerivedFields`, where it runs at
    /// the moment its result is used and cannot be stale at all.
    ///
    /// `refresh(task:)` itself is deliberately left alone. It is the durable
    /// launch path, where callers depend on the write having happened by the
    /// time it returns.
    @MainActor
    public static func refreshLoadingOffMainActor(task: AgentTask, followUpMessage: String = "") async {
        // Read off the model before leaving the actor; the load takes only
        // sendable values.
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id

        // Retried off the actor rather than repaired on it: recovering by
        // redoing the refresh under the actor spends exactly what this avoids.
        // Bounded, because a file under continuous rewriting would otherwise
        // retry forever.
        for _ in 0..<maxRevalidationAttempts {
            guard let loaded = await loadOffActor(workspacePath: workspacePath, taskID: taskID) else { return }
            #if DEBUG
            // Runs on the main actor in exactly the window the guards below
            // exist for, so a test can create the interleaving deterministically
            // instead of racing it. DEBUG-only: never present in a release build.
            interleaveForTesting?()
            #endif
            // Before anything that costs: a superseded refresh must not spend
            // the actor on work the user has already navigated away from.
            guard !Task.isCancelled else { return }
            // Reading properties off a deleted model is unsafe — see the
            // membership rules in `SidebarTaskStore` — and `applyRefresh`
            // traverses them.
            //
            // Deliberately untested: the hazard is undefined behaviour, and
            // SwiftData serves a deleted model's cached values often enough
            // that no assertion distinguishes guarded from unguarded. A test
            // here would pass either way and imply coverage it does not have.
            guard !task.isDeleted, task.modelContext != nil else { return }
            // The workspace can be repointed while this runs, from another
            // window. The task stays attached and its id does not change, so
            // nothing else here notices — but `loaded.folder` then names the
            // old workspace, and applying would write this task's state
            // somewhere it no longer reads from. Retrying would re-derive the
            // same stale path, so this one goes to the actor.
            guard TaskWorkspaceAccess(task: task).effectiveWorkspacePath == workspacePath else {
                fallBack(task: task, followUpMessage: followUpMessage)
                return
            }
            // An unusable load is a corrupt or unknown-schema file, and
            // recovering from it *writes*. That has to happen under the same
            // serialization as the writers, and retrying would only re-read
            // the same bad bytes.
            guard loaded.loadWasUsable else {
                fallBack(task: task, followUpMessage: followUpMessage)
                return
            }
            // Nothing serialized the load against the main actor, so anything
            // that writes this file — `recordTurn` most obviously — may have
            // landed while we were away. Deriving from a snapshot that
            // predates it would silently drop the newer turn. One stat, on one
            // file, against the read it validates.
            guard !loaded.readStraddledAWrite,
                  FileStamp(atPath: statePath(inFolder: loaded.folder)) == loaded.stamp else {
                #if DEBUG
                revalidationRetryCountForTesting += 1
                #endif
                continue
            }
            applyRefresh(
                existing: loaded.existing,
                folder: loaded.folder,
                task: task,
                followUpMessage: followUpMessage
            )
            return
        }
        // Still moving after every attempt. Take the actor path once rather
        // than spin: a refresh that never lands is worse than a slow one.
        fallBack(task: task, followUpMessage: followUpMessage)
    }

    /// How many times a load invalidated by a concurrent write is retried off
    /// the actor before giving up and doing it on the actor.
    private static let maxRevalidationAttempts = 3

    /// Redoes the whole refresh under the actor. Every guard above ends here
    /// when it cannot trust what the load brought back.
    @MainActor
    private static func fallBack(task: AgentTask, followUpMessage: String) {
        #if DEBUG
        fallbackCountForTesting += 1
        #endif
        refresh(task: task, followUpMessage: followUpMessage)
    }

    /// The off-actor half: resolve the folder and read the state.
    ///
    /// `nonisolated` rather than `Task.detached`. A detached task inherits
    /// nothing, cancellation included, so cancelling the caller left this
    /// running to completion. A nonisolated async function called from the
    /// actor runs off it just the same, and does inherit cancellation.
    private nonisolated static func loadOffActor(
        workspacePath: String,
        taskID: UUID
    ) async -> LoadedContextState? {
        guard !Task.isCancelled else { return nil }
        guard let folder = try? TaskFolderResolvingAdapter.ensureTaskFolder(
            workspacePath: workspacePath,
            taskID: taskID
        ), !folder.isEmpty else { return nil }
        let path = statePath(inFolder: folder)

        // Bracketed, because stamping only after the read is worse than
        // useless: a writer landing inside the read leaves `existing` holding
        // the old bytes while the stamp describes the writer's file, so the
        // check at the apply matches and puts the stale snapshot straight back
        // over them. Two stamps that disagree mean the read straddled a write
        // and neither describes the other.
        let beforeRead = FileStamp(atPath: path)
        // `loadResult` reads and decodes and nothing else. `recoverState`,
        // which used to be called here, is not read-only: on a corrupt file it
        // *moves* it to quarantine. Off the actor that races every writer — it
        // could observe a decode failure, let `recordTurn` replace the file
        // with good state, and then quarantine that new file, losing the turn.
        let result = loadResult(taskFolder: folder)
        // A missing file is the ordinary case for a new or imported task, and
        // `TaskContextStateRecovery` treats it as one: nothing to recover, so
        // nothing to serialize. Only the statuses whose recovery *writes* have
        // to go back to the actor.
        let usable = result.status == .loadedCurrent
            || result.status == .migratedLegacy
            || result.status == .missingFile
        let existing = usable ? result.state : nil
        #if DEBUG
        interleaveDuringLoadForTesting?()
        #endif
        let afterRead = FileStamp(atPath: path)
        return LoadedContextState(
            folder: folder,
            existing: existing,
            stamp: afterRead,
            readStraddledAWrite: beforeRead != afterRead,
            loadWasUsable: usable
        )
    }

    #if DEBUG
    /// Counts how often the apply gave up and took the synchronous path.
    /// Several of the guards here are only observable as "did it fall back",
    /// and a fallback costs the main-actor work this change exists to avoid.
    @MainActor
    static var fallbackCountForTesting = 0

    /// Counts loads thrown away because the state file moved under them and
    /// retried off the actor. Distinguishes "revalidation worked" from
    /// "revalidation never fired".
    @MainActor
    static var revalidationRetryCountForTesting = 0

    /// Test seam for `refreshLoadingOffMainActor`, on the main actor after the
    /// load returns. See its call site.
    @MainActor
    static var interleaveForTesting: (@MainActor () -> Void)?

    /// Test seam that runs *inside* the off-actor load, after the read and
    /// before the closing stamp — the window where a write leaves `existing`
    /// stale while the stamp describes the writer's file.
    nonisolated(unsafe) static var interleaveDuringLoadForTesting: (@Sendable () -> Void)?
    #endif

    @MainActor
    public static func refreshedPromptContext(for task: AgentTask, followUpMessage: String = "") -> String? {
        refresh(task: task, followUpMessage: followUpMessage)
        return promptContext(for: task)
    }
}
