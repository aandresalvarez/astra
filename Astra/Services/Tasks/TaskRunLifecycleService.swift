import Foundation
import SwiftData

enum TaskRunInterruptionSource {
    case userAction
    case queueStopped
    case appRestart
    case supersededByNewRun

    var auditSource: String {
        switch self {
        case .userAction: return "user_action"
        case .queueStopped: return "queue_stopped"
        case .appRestart: return "startup_recovery"
        case .supersededByNewRun: return "superseded_by_new_run"
        }
    }

    var eventType: TaskEventType {
        switch self {
        case .appRestart, .supersededByNewRun: return TaskEventTypes.Task.interrupted
        case .userAction, .queueStopped: return TaskEventTypes.Task.cancelled
        }
    }

    var eventPayload: String {
        switch self {
        case .userAction:
            return "Task cancelled by user."
        case .queueStopped:
            return "Task cancelled because the running queue was stopped."
        case .appRestart:
            return "Task run was interrupted because ASTRA restarted before the worker finished."
        case .supersededByNewRun:
            return "Previous run was interrupted before starting a new run."
        }
    }

    var runStopReason: TaskRunStopReason {
        switch self {
        case .userAction: return .cancelled
        case .queueStopped: return "queue_cancelled"
        case .appRestart: return .appRestarted
        case .supersededByNewRun: return .superseded
        }
    }

    var alwaysCancelTask: Bool {
        switch self {
        case .userAction, .queueStopped: return true
        case .appRestart, .supersededByNewRun: return false
        }
    }

    var cancelsActiveTaskStatus: Bool {
        switch self {
        case .userAction, .queueStopped, .appRestart: return true
        case .supersededByNewRun: return false
        }
    }
}

@MainActor
struct TaskRunInterruptionSummary {
    var tasksUpdated = 0
    var runsUpdated = 0
    var eventsInserted = 0
    private(set) var affectedWorkspaces: [Workspace] = []
    private var affectedWorkspaceIDs: Set<UUID> = []

    var hasChanges: Bool {
        tasksUpdated > 0 || runsUpdated > 0 || eventsInserted > 0
    }

    mutating func add(_ other: TaskRunInterruptionSummary) {
        tasksUpdated += other.tasksUpdated
        runsUpdated += other.runsUpdated
        eventsInserted += other.eventsInserted
        for workspace in other.affectedWorkspaces {
            addAffectedWorkspace(workspace)
        }
    }

    mutating func addAffectedWorkspace(_ workspace: Workspace?) {
        guard let workspace, !affectedWorkspaceIDs.contains(workspace.id) else { return }
        affectedWorkspaceIDs.insert(workspace.id)
        affectedWorkspaces.append(workspace)
    }
}

@MainActor
enum TaskRunLifecycleService {
    @discardableResult
    static func cancelTask(
        _ task: AgentTask,
        modelContext: ModelContext,
        source: TaskRunInterruptionSource,
        at finishedAt: Date = Date()
    ) -> TaskRunInterruptionSummary {
        finalizeInterruptedRuns(
            for: task,
            modelContext: modelContext,
            source: source,
            at: finishedAt
        )
    }

    @discardableResult
    static func cancelAllRunningTasks(
        modelContext: ModelContext,
        source: TaskRunInterruptionSource = .queueStopped,
        at finishedAt: Date = Date()
    ) -> TaskRunInterruptionSummary {
        let tasks = fetchIncompleteTasks(modelContext: modelContext)
        var summary = TaskRunInterruptionSummary()
        for task in tasks where task.status == .running {
            summary.add(finalizeInterruptedRuns(
                for: task,
                modelContext: modelContext,
                source: source,
                at: finishedAt
            ))
        }
        persist(summary: summary, modelContext: modelContext)
        return summary
    }

    @discardableResult
    static func recoverOrphanedRunningRuns(
        modelContext: ModelContext,
        at recoveredAt: Date = Date(),
        autoExportWorkspaces: Bool = true
    ) -> TaskRunInterruptionSummary {
        let tasks = fetchOrphanRecoveryCandidates(modelContext: modelContext)
        var summary = TaskRunInterruptionSummary()

        for task in tasks {
            let hasRunningRun = task.runs.contains { $0.status == .running }
            let hasOrphanedTaskStatus = task.status == .running || task.status == .pendingUser
            guard hasRunningRun || hasOrphanedTaskStatus else { continue }

            summary.add(finalizeInterruptedRuns(
                for: task,
                modelContext: modelContext,
                source: .appRestart,
                at: recoveredAt
            ))
        }

        if summary.hasChanges {
            AppLogger.audit(.taskInterrupted, category: "App", fields: [
                "source": TaskRunInterruptionSource.appRestart.auditSource,
                "tasks_updated": String(summary.tasksUpdated),
                "runs_updated": String(summary.runsUpdated),
                "events_inserted": String(summary.eventsInserted)
            ], level: .warning)
        }
        persist(
            summary: summary,
            modelContext: modelContext,
            autoExportWorkspaces: autoExportWorkspaces
        )
        return summary
    }

    static func persist(
        summary: TaskRunInterruptionSummary,
        modelContext: ModelContext,
        autoExportWorkspaces: Bool = true
    ) {
        guard summary.hasChanges else { return }
        if summary.affectedWorkspaces.isEmpty || !autoExportWorkspaces {
            // A nil workspace routes through the coordinator's synchronous save
            // path without triggering a workspace JSON auto-export, preserving
            // the `autoExportWorkspaces: false` contract for callers that batch
            // exports themselves.
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: nil,
                modelContext: modelContext,
                auditFields: ["operation": "persist_interrupted_runs"]
            )
        } else {
            for workspace in summary.affectedWorkspaces {
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: workspace,
                    modelContext: modelContext
                )
            }
        }
    }

    private static func finalizeInterruptedRuns(
        for task: AgentTask,
        modelContext: ModelContext,
        source: TaskRunInterruptionSource,
        at finishedAt: Date
    ) -> TaskRunInterruptionSummary {
        var summary = TaskRunInterruptionSummary()
        let runningRuns = task.runs
            .filter { $0.status == .running }
            .sorted { $0.startedAt < $1.startedAt }

        for run in runningRuns {
            run.status = .cancelled
            run.completedAt = finishedAt
            run.typedStopReason = source.runStopReason
            // Bound output on this terminal transition too: a run cancelled mid-
            // stream can carry a large partial output. Assign only on change.
            let cappedOutput = TaskRunOutputCap.capped(run.output)
            if cappedOutput != run.output {
                run.output = cappedOutput
            }
            summary.runsUpdated += 1
        }

        let shouldCancelTask = source.alwaysCancelTask
            || (source.cancelsActiveTaskStatus && (task.status == .running || task.status == .pendingUser))

        if shouldCancelTask {
            let result = TaskStateMachine.cancelFromLifecycle(
                task,
                modelContext: modelContext,
                at: finishedAt
            )
            if result.changed {
                summary.tasksUpdated += 1
            }
        }

        if summary.runsUpdated > 0 || summary.tasksUpdated > 0 || source.alwaysCancelTask {
            task.updatedAt = finishedAt
            let event = TaskEvent(
                task: task,
                eventType: source.eventType,
                payload: source.eventPayload,
                run: runningRuns.last
            )
            event.timestamp = finishedAt
            modelContext.insert(event)
            summary.eventsInserted += 1
            summary.addAffectedWorkspace(task.workspace)
        }

        return summary
    }

    // Note on the fetches below: we deliberately predicate on `completedAt ==
    // nil` rather than on the status enum. SwiftData `#Predicate` enum-equality
    // is unreliable across store backends (it silently matches nothing on the
    // in-memory store), whereas nil comparisons are well supported. A running /
    // pendingUser task and a running run always have `completedAt == nil` (that
    // field is only set when finalizing), so this narrows the fetch to the
    // open set and we refine the exact status in memory — same result as a full
    // scan, without faulting the runs of every historical task.

    private static func fetchIncompleteTasks(modelContext: ModelContext) -> [AgentTask] {
        let descriptor = FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.completedAt == nil }
        )
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "fetch_incomplete_tasks",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            // Fall back to a full scan so recovery still works correctly.
            return (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
        }
    }

    private static func fetchIncompleteRuns(modelContext: ModelContext) -> [TaskRun] {
        let descriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.completedAt == nil }
        )
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "fetch_incomplete_runs",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return (try? modelContext.fetch(FetchDescriptor<TaskRun>())) ?? []
        }
    }

    /// Tasks that may need interrupted-run recovery after a restart, narrowed
    /// to the open set so we never materialize and run-fault the entire task
    /// history. Union of: tasks whose own status is orphaned (running /
    /// pendingUser), and parents of any run still marked running.
    private static func fetchOrphanRecoveryCandidates(modelContext: ModelContext) -> [AgentTask] {
        var candidates: [UUID: AgentTask] = [:]

        for task in fetchIncompleteTasks(modelContext: modelContext)
        where task.status == .running || task.status == .pendingUser {
            candidates[task.id] = task
        }

        for run in fetchIncompleteRuns(modelContext: modelContext) where run.status == .running {
            if let task = run.task {
                candidates[task.id] = task
            }
        }

        return Array(candidates.values)
    }
}
