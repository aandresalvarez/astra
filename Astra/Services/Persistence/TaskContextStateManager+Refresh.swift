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
        /// Identity, as the scan finished, of every directory the inventory
        /// came from. The scan used to run at the moment of use; off-actor it
        /// can go stale in the hop back.
        let directoryStamps: [String: FileStamp]
        /// A scanned directory changed identity during the scan, so the
        /// inventory may describe two different moments.
        let scanStraddledAChange: Bool
        /// Whether the load came back in a state this path can use. Anything
        /// else has to be handled on the actor, because recovering from it
        /// writes.
        let loadWasUsable: Bool
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

    /// Every directory under `folder` the output scan would traverse.
    ///
    /// Both of the scan's subtree prunes, not just the broker's. The second
    /// one is the load-bearing one: an agent that runs `python -m venv` in its
    /// task folder adds ~15,000 entries, and every directory kept here is
    /// re-stat'd on the main actor at the apply. Walking a dependency tree
    /// would therefore put a far worse freeze on task selection than the one
    /// this change removes.
    private nonisolated static func scannedDirectories(under folder: String) -> [String] {
        let root = URL(fileURLWithPath: folder)
        let broker = HostFileAccessBroker()
        let intent = HostFileAccessIntent.astraManagedStorage(root: root)
        var directories = [folder]
        guard let enumerator = broker.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            intent: intent
        ) else { return directories }
        while let url = enumerator.nextObject() as? URL {
            // Polled inside the walk: inheriting the flag does not interrupt a
            // synchronous enumerator, so without this a cancelled refresh
            // still walks the whole tree.
            if Task.isCancelled { return directories }
            guard !broker.shouldSkip(url, intent: intent) else {
                enumerator.skipDescendants()
                continue
            }
            guard !TaskOutputArtifactPathPolicy.isGeneratedDependencyDirectoryName(url.lastPathComponent) else {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            directories.append(url.standardizedFileURL.path)
        }
        return directories
    }

    /// Stamps every scanned directory, plus the parent of each discovered file
    /// in case the walk and the scan disagree. Adding or removing an entry
    /// moves its directory's identity, so re-stamping these at the apply spots
    /// an inventory that went stale in the hop back.
    ///
    /// One thing it does not catch, stated rather than implied: a file
    /// rewritten in place moves no directory. That rides the next refresh, as
    /// it did before any of this moved off the actor.
    private nonisolated static func stamps(
        for directories: [String],
        files: [TaskOutputDiscoveredFile]
    ) -> [String: FileStamp] {
        var paths = Set(directories)
        for file in files {
            paths.insert(URL(fileURLWithPath: file.path).deletingLastPathComponent().path)
        }
        return paths.reduce(into: [:]) { stamps, path in
            stamps[path] = FileStamp(atPath: path)
        }
    }

    @MainActor
    public static func refreshLoadingOffMainActor(task: AgentTask, followUpMessage: String = "") async {
        // Read off the model before leaving the actor; the load takes only
        // sendable values.
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskID = task.id

        // Retried off the actor rather than repaired on it. An invalidated
        // load means the folder moved while it was being read, which is most
        // likely while a run is producing outputs — the case this whole change
        // exists for. Recovering by rescanning synchronously would put the
        // freeze back exactly there. Bounded, because a folder under
        // continuous change would otherwise retry forever.
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
            // somewhere it no longer reads from. Retrying would just re-derive
            // the same stale path, so this one goes to the actor.
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
            // that writes the state file — `recordTurn` most obviously — or
            // adds an output may have landed while we were away. Deriving from
            // a snapshot that predates it would silently drop the newer work.
            guard !loaded.readStraddledAWrite,
                  !loaded.scanStraddledAChange,
                  FileStamp(atPath: statePath(inFolder: loaded.folder)) == loaded.stamp,
                  loaded.directoryStamps.allSatisfy({ FileStamp(atPath: $0.key) == $0.value }) else {
                #if DEBUG
                revalidationRetryCountForTesting += 1
                #endif
                continue
            }
            applyRefresh(
                existing: loaded.existing,
                folder: loaded.folder,
                task: task,
                followUpMessage: followUpMessage,
                discoveredFiles: loaded.discoveredFiles
            )
            return
        }
        // Still moving after every attempt. Take the actor path once rather
        // than spin: a refresh that never lands is worse than a slow one.
        fallBack(task: task, followUpMessage: followUpMessage)
    }

    /// How many times a load invalidated by a moving folder is retried off the
    /// actor before giving up and doing it on the actor.
    private static let maxRevalidationAttempts = 3

    /// Redoes the whole refresh under the actor, rescan included. Every guard
    /// above ends here when it cannot trust what the load brought back.
    @MainActor
    private static func fallBack(task: AgentTask, followUpMessage: String) {
        #if DEBUG
        fallbackCountForTesting += 1
        #endif
        refresh(task: task, followUpMessage: followUpMessage)
    }

    /// The off-actor half: resolve the folder, read the state, take the
    /// inventory.
    ///
    /// `nonisolated` rather than `Task.detached`, which is what this used to
    /// be. A detached task inherits nothing, cancellation included, so
    /// cancelling the caller left the recursive scan running to completion and
    /// a burst of generated-file updates still stacked concurrent scans — the
    /// thing the caller's cancel-then-launch was added to stop. A nonisolated
    /// async function called from the actor runs off it just the same, and
    /// does inherit cancellation, so the checks below actually bind.
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

        guard !Task.isCancelled else { return nil }
        // Every directory the scan traverses, taken before it runs: derived
        // from the discovered files alone this misses an empty one, and the
        // first artifact written into a pre-created `outputs/` moves only that
        // directory, not the root.
        let before = scannedDirectories(under: folder)
        guard !Task.isCancelled else { return nil }
        let beforeScan = stamps(for: before, files: [])
        let discovered = TaskOutputDiscovery.files(in: folder)
        guard !Task.isCancelled else { return nil }
        #if DEBUG
        interleaveDuringScanForTesting?()
        #endif
        // Walked again, and the two unioned, because one walk cannot describe
        // a directory that did not exist when it ran.
        //
        // Deliberately untested. The window is between the first walk and its
        // stamps: a directory created while the scan runs already moves the
        // root, which the bracket catches, so every seam this file has reaches
        // a case that passes either way. Covering the real window needs a
        // sixth test hook in production code for a sub-millisecond gap, which
        // costs more than the guard does. A run creating an empty
        // nested directory between that walk and its stamps leaves the new
        // directory untracked *and* its parent's baseline already carrying the
        // creation — so the first file written inside it moves only something
        // nothing is watching, and the stale inventory passes.
        let after = scannedDirectories(under: folder)
        let tracked = Array(Set(before).union(after))
        // Bracketed like the read, and over every scanned directory rather
        // than the root alone: a change landing inside the enumeration leaves
        // the inventory describing one moment and the stamps another. A
        // directory that appeared during it counts as such a change.
        let afterScan = stamps(for: tracked, files: discovered)
        // Sets, not counts: directory churn can remove one path and add
        // another between the walks, leaving the counts equal while the
        // removed path has no stamp on either side and the replacement's
        // baseline is already post-change. Comparing sizes reports no change
        // and persists an inventory missing whatever lands in the new one.
        let moved = before.contains { beforeScan[$0] != afterScan[$0] }
            || Set(after) != Set(before)
        return LoadedContextState(
            folder: folder,
            existing: existing,
            stamp: afterRead,
            readStraddledAWrite: beforeRead != afterRead,
            discoveredFiles: discovered,
            directoryStamps: afterScan,
            scanStraddledAChange: moved,
            loadWasUsable: usable
        )
    }

    #if DEBUG
    /// Counts how often the apply gave up and took the synchronous path.
    /// Several of the guards here are only observable as "did it fall back",
    /// and a fallback costs the main-actor rescan this change exists to avoid.
    @MainActor
    static var fallbackCountForTesting = 0

    /// Counts loads thrown away because the folder moved under them and
    /// retried off the actor. Distinguishes "revalidation worked" from
    /// "revalidation never fired".
    @MainActor
    static var revalidationRetryCountForTesting = 0

    /// Test seam for `refreshLoadingOffMainActor`, on the main actor after the
    /// load returns. See its call site.
    @MainActor
    static var interleaveForTesting: (@MainActor () -> Void)?

    /// Test seam that runs *inside* the detached load, after the read and
    /// before the closing stamp — the window where a write leaves `existing`
    /// stale while the stamp describes the writer's file.
    nonisolated(unsafe) static var interleaveDuringLoadForTesting: (@Sendable () -> Void)?

    /// Test seam inside the *scan* bracket — after the inventory is taken and
    /// before the closing folder stamp — so a test can make the inventory
    /// stale the way a running task does.
    nonisolated(unsafe) static var interleaveDuringScanForTesting: (@Sendable () -> Void)?
    #endif

    @MainActor
    public static func refreshedPromptContext(for task: AgentTask, followUpMessage: String = "") -> String? {
        refresh(task: task, followUpMessage: followUpMessage)
        return promptContext(for: task)
    }
}
