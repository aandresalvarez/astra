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

    var eventType: String {
        switch self {
        case .appRestart, .supersededByNewRun: return "task.interrupted"
        case .userAction, .queueStopped: return "task.cancelled"
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

    var runStopReason: String {
        switch self {
        case .userAction: return "cancelled"
        case .queueStopped: return "queue_cancelled"
        case .appRestart: return "app_restarted"
        case .supersededByNewRun: return "superseded"
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
        let tasks = fetchAllTasks(modelContext: modelContext)
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
        at recoveredAt: Date = Date()
    ) -> TaskRunInterruptionSummary {
        let tasks = fetchAllTasks(modelContext: modelContext)
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
        persist(summary: summary, modelContext: modelContext)
        return summary
    }

    static func persist(summary: TaskRunInterruptionSummary, modelContext: ModelContext) {
        guard summary.hasChanges else { return }
        if summary.affectedWorkspaces.isEmpty {
            do {
                try modelContext.save()
            } catch {
                AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                    "operation": "persist_interrupted_runs",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
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
            run.stopReason = source.runStopReason
            summary.runsUpdated += 1
        }

        let shouldCancelTask = source.alwaysCancelTask
            || (source.cancelsActiveTaskStatus && (task.status == .running || task.status == .pendingUser))

        if shouldCancelTask {
            if task.status != .cancelled {
                task.status = .cancelled
                summary.tasksUpdated += 1
            }
            task.completedAt = finishedAt
            task.markRead()
        }

        if summary.runsUpdated > 0 || summary.tasksUpdated > 0 || source.alwaysCancelTask {
            task.updatedAt = finishedAt
            let event = TaskEvent(
                task: task,
                type: source.eventType,
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

    private static func fetchAllTasks(modelContext: ModelContext) -> [AgentTask] {
        do {
            return try modelContext.fetch(FetchDescriptor<AgentTask>())
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "fetch_tasks_for_run_lifecycle",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return []
        }
    }
}
