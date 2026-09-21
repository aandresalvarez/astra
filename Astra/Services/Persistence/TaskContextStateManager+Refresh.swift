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
        /// The task folder's contents, enumerated here rather than on the main
        /// actor inside `updateDerivedFields`.
        let discoveredFiles: [TaskOutputDiscoveredFile]
    }

    /// Cheap identity of a file: enough to detect that someone replaced it,
    /// without re-reading and re-decoding the thing we went off-actor to avoid.
    private struct FileStamp: Equatable, Sendable {
        let modified: Date
        let size: Int

        init?(atPath path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int else { return nil }
            self.modified = modified
            self.size = size
        }
    }

    private static func statePath(inFolder folder: String) -> String {
        URL(fileURLWithPath: folder).appendingPathComponent(jsonFileName).path
    }

    /// `refresh(task:)` with its filesystem work moved off the main actor.
    ///
    /// `refresh` resolves the task folder — which runs a legacy-layout
    /// migration check and creates two directories — then reads and decodes
    /// `current_state.json`, and then, inside `updateDerivedFields`, enumerates
    /// the whole task folder and resolves every file in it. All of that ran
    /// before it touched any model state. On
    /// task open that whole sequence runs on the main thread, and production
    /// samples of the `context_state_refresh` phase put it at p50 60 ms, p90
    /// 178 ms, max 706 ms — a freeze the user feels when selecting a task.
    ///
    /// Both steps are pure functions of a workspace path and a task id, so
    /// they move off-actor unchanged. Everything that reads the SwiftData
    /// model stays on the main actor in `applyRefresh`, and the save stays
    /// there too, so durability ordering is untouched — and the common
    /// task-open case is a no-op refresh that never saves at all.
    ///
    /// `refresh(task:)` itself is deliberately left alone: it is the durable
    /// launch path, where callers depend on the write having happened by the
    /// time it returns.
    @MainActor
    public static func refreshLoadingOffMainActor(task: AgentTask, followUpMessage: String = "") async {
        // Read off the model before leaving the actor; the detached work takes
        // only sendable values.
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedContextState? in
            guard let folder = try? TaskFolderResolvingAdapter.ensureTaskFolder(
                workspacePath: workspacePath,
                taskID: taskID
            ), !folder.isEmpty else { return nil }
            let path = statePath(inFolder: folder)
            // Bracketed, because stamping only after the read is worse than
            // useless: a writer landing inside the read leaves `existing`
            // holding the old bytes while the stamp describes the writer's
            // file, so the check at the apply matches and puts the stale
            // snapshot straight back over them. Two stamps that disagree mean
            // the read straddled a write and neither describes the other.
            let beforeRead = FileStamp(atPath: path)
            let existing = TaskContextStateRecovery.recoverState(taskFolder: folder, taskID: taskID)
            #if DEBUG
            interleaveDuringLoadForTesting?()
            #endif
            let afterRead = FileStamp(atPath: path)
            return LoadedContextState(
                folder: folder,
                existing: existing,
                stamp: afterRead,
                readStraddledAWrite: beforeRead != afterRead,
                discoveredFiles: TaskOutputDiscovery.files(in: folder)
            )
        }.value
        guard let loaded else { return }
        #if DEBUG
        // Runs on the main actor in exactly the window the two guards below
        // exist for, so a test can create the interleaving deterministically
        // instead of racing it. DEBUG-only: never present in a release build.
        interleaveForTesting?()
        #endif
        // Reading properties off a deleted model is unsafe — see the membership
        // rules in `SidebarTaskStore` — and `applyRefresh` traverses them. The
        // task-open caller now awaits, so `.task(id:)` cancels it, but the
        // generated-files caller is still unstructured and can resume after a
        // delete.
        //
        // Deliberately untested: the hazard is undefined behaviour, and
        // SwiftData serves a deleted model's cached values often enough that no
        // assertion distinguishes guarded from unguarded. A test here would
        // pass either way and imply coverage it does not have.
        guard !task.isDeleted, task.modelContext != nil else { return }
        // Nothing serialized the read above against the main actor, so anything
        // that writes this file — `recordTurn` most obviously — may have landed
        // while we were away. Deriving from `loaded.existing` would then save a
        // snapshot that predates it and silently drop the newer turn. A stat is
        // microseconds against the read it validates, so re-check identity and
        // fall back to the synchronous path, which re-reads under the actor.
        guard !loaded.readStraddledAWrite,
              FileStamp(atPath: statePath(inFolder: loaded.folder)) == loaded.stamp else {
            refresh(task: task, followUpMessage: followUpMessage)
            return
        }
        // Awaiting a detached task neither cancels it nor stops a cancelled
        // caller resuming, so a task switch can land here after the next task
        // has already initialised. Applying now would write this task's domain
        // state and then its presentation state over the new one's.
        guard !Task.isCancelled else { return }
        applyRefresh(
            existing: loaded.existing,
            folder: loaded.folder,
            task: task,
            followUpMessage: followUpMessage,
            discoveredFiles: loaded.discoveredFiles
        )
    }

    #if DEBUG
    /// Test seam for `refreshLoadingOffMainActor`, on the main actor after the
    /// load returns. See its call site.
    @MainActor
    static var interleaveForTesting: (@MainActor () -> Void)?

    /// Test seam that runs *inside* the detached load, after the read and
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
