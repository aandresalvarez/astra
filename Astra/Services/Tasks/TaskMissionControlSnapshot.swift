import Foundation
import ASTRAModels
import ASTRAPersistence

/// The decision dock's mission-control summary, and the task folder it was
/// read from.
///
/// **Why it is cached, and built in two halves.** `TaskMainView.body` reads
/// `messageText`, so it re-runs on every keystroke in the composer, and it used
/// to build this snapshot two or three times per pass: once for the dock's
/// `mission:` argument, once for the verification request the dock's cached
/// verification is compared against, and once more for the `.task(id:)` keyed
/// on that request. Each build `stat`ed the task folder and read and decoded
/// `current_state.json` on the main thread.
///
/// It is now a `@State` cache on the view, rebuilt under `.task(id: Inputs)`:
/// `Source.loaded` is the disk half and runs off the main actor, `build` reads
/// the model on the main actor. The wiring is in
/// `TaskMainViewMissionControl.swift`.
struct TaskMissionControlSnapshot: Equatable {
    static let empty = TaskMissionControlSnapshot(taskID: nil, taskFolder: "", presentation: nil)

    /// The task this was built for. The view is keyed by task id, so this only
    /// guards the window before the first rebuild lands.
    let taskID: UUID?
    let taskFolder: String
    let presentation: MissionControlPresentation?

    /// What the snapshot reads from disk. Plain values, so it can be produced
    /// off the main actor.
    struct Source: Sendable {
        let taskFolder: String
        let state: TaskContextState?

        /// Resolves the task folder — a `fileExists` or two, for the legacy
        /// layout — then reads and decodes `current_state.json`.
        static func load(workspacePath: String, taskID: UUID) -> Source {
            let folder = TaskFolderResolvingAdapter.taskFolder(workspacePath: workspacePath, taskID: taskID)
            return Source(
                taskFolder: folder,
                state: folder.isEmpty ? nil : TaskContextStateManager.load(taskFolder: folder)
            )
        }

        /// `load`, off the main actor and cancelled with its caller: nil if
        /// the rebuild that asked was superseded before the read began.
        /// `nonisolated async` rather than `Task.detached`, which inherits no
        /// cancellation and would finish every superseded read and decode —
        /// the reasoning at `TaskContextStateManager.loadOffActor`.
        nonisolated static func loaded(workspacePath: String, taskID: UUID) async -> Source? {
            guard !Task.isCancelled else { return nil }
            return load(workspacePath: workspacePath, taskID: taskID)
        }
    }

    /// Everything the snapshot depends on, as values `body` already holds:
    /// comparing two of these costs no syscalls and faults no relationships,
    /// and `messageText` is not among them.
    ///
    /// - `stateRevision` stands for the file. The view bumps it whenever
    ///   `saveState` writes this task's `current_state.json` — which is how a
    ///   turn recorded at the end of a run reaches the dock — and after its own
    ///   context refresh, which can move the task folder without a save.
    /// - `status`, `goal` and `plan` are the model fields
    ///   `MissionControlPresentation.build` reads next to the file.
    /// - The run count and the latest run stand in for the relationships it
    ///   falls back on when there is no state file (`task.artifacts`, each
    ///   run's file changes). Those are reconciled at run finalize, which moves
    ///   the latest run's status with them.
    /// - Events matter only as "are there any", so the key holds exactly that.
    ///   An exact count would rebuild, and reread the file, on every runtime
    ///   event a streaming run records.
    ///
    /// Deliberately absent: `task.updatedAt`, which every runtime event bumps
    /// (`TaskPlanStateRefreshTrigger` has the numbers), and the token and cost
    /// totals, which move with each usage event while a run streams. The dock
    /// never shows `budgetSummary`, and the run's status change at the end
    /// brings it up to date anyway.
    struct Inputs: Equatable {
        let taskID: UUID
        let workspacePath: String
        let status: TaskStatus
        let goal: String
        let plan: TaskPlanPayload?
        let runCount: Int
        let hasEvents: Bool
        let latestRunID: UUID?
        let latestRunStatus: RunStatus?
        let stateRevision: Int

        @MainActor
        init(task: AgentTask, thread: TaskThreadSnapshot?, planState: TaskPlanState, stateRevision: Int) {
            taskID = task.id
            workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
            status = task.status
            goal = task.goal
            plan = planState.plan
            runCount = thread?.totalRunCount ?? 0
            hasEvents = (thread?.totalEventCount ?? 0) > 0
            latestRunID = thread?.latestRun?.id
            latestRunStatus = thread?.latestRun?.status
            self.stateRevision = stateRevision
        }
    }

    @MainActor
    static func build(task: AgentTask, planState: TaskPlanState, source: Source) -> TaskMissionControlSnapshot {
        TaskMissionControlSnapshot(
            taskID: task.id,
            taskFolder: source.taskFolder,
            presentation: MissionControlPresentation.build(
                task: task,
                planState: planState,
                state: source.state
            )
        )
    }

    /// Whether, after the view's own context refresh, the cached snapshot was
    /// read from a folder the task no longer resolves to, without anything
    /// having said so. A save announced itself, and the rebuild it triggers
    /// resolves the folder afresh, so that is never a reason to reload again.
    ///
    /// Judged against the folder the cache was built from, not the folder
    /// before this refresh: a refresh cancelled after migrating a legacy
    /// folder never reports it, and the one that replaces it starts from the
    /// new folder. An empty cache is not stale — its first load has not
    /// landed, and checks its own folder when it does.
    static func contextRefreshLeftSnapshotStale(
        announcedSave: Bool,
        cachedFolder: String,
        currentFolder: String
    ) -> Bool {
        !announcedSave && !cachedFolder.isEmpty && cachedFolder != currentFolder
    }

    /// Not part of the cached snapshot: it carries `task.updatedAt`, and the
    /// verification reload is keyed on exactly that. Only the folder comes
    /// from the cache, which is what spares `body` the `stat`.
    static func verificationLoadRequest(
        task: AgentTask,
        taskFolder: String,
        isFinished: Bool
    ) -> TaskVerificationLoadRequest? {
        guard isFinished, !taskFolder.isEmpty else { return nil }
        return TaskVerificationLoadRequest(
            taskID: task.id,
            taskStatus: task.status,
            taskUpdatedAt: task.updatedAt,
            taskFolder: taskFolder
        )
    }
}
