import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The pre-run snapshot kept on disk for the length of the run, so a run ASTRA
/// did not live to finish can still be compared. Without it the baseline lives
/// only in the worker's memory, and a crash or quit mid-run leaves that run
/// with no observed changes at all.
///
/// It sits in the task folder's `diagnostics/`, which the Files shelf and the
/// snapshot itself never show, one file per run. The worker writes it after
/// the pre-run walk, `recordChanges` removes it when the run ends normally,
/// and `recoverInterruptedRuns` replays and removes it at the next launch.
extension TaskFolderRunSnapshot {
    struct PersistedBaseline: Codable {
        static let currentVersion = 1
        let version: Int
        let runID: UUID
        let taskFolder: String
        let entries: [String: Entry]
    }

    enum BaselineLoad: Sendable {
        case missing
        case unreadable
        case loaded(TaskFolderRunSnapshot)
    }

    static let baselineFilePrefix = "task_folder_baseline_"

    static func baselineURL(taskFolder: String, runID: UUID) -> URL {
        URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("\(baselineFilePrefix)\(runID.uuidString).json")
    }

    /// Writes the baseline for `run`, off the main actor. A write that fails
    /// only costs crash recovery, so it is logged and the run goes on.
    @MainActor
    static func persistBaseline(_ baseline: TaskFolderRunSnapshot?, task: AgentTask, run: TaskRun) async {
        guard let baseline else { return }
        let runID = run.id
        let written = await Task.detached(priority: .utility) {
            writeBaseline(baseline, runID: runID)
        }.value
        guard !written else { return }
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "event": "task_folder_baseline_not_persisted",
            "run_id": String(runID.uuidString.prefix(8))
        ], level: .warning)
    }

    /// Also removes every other baseline in the folder. A task runs one turn
    /// at a time, so any other is left from a run that ended without cleaning
    /// up — its recovery failed, or it was superseded before a relaunch.
    static func writeBaseline(_ baseline: TaskFolderRunSnapshot, runID: UUID) -> Bool {
        let url = baselineURL(taskFolder: baseline.root.standardized, runID: runID)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix(baselineFilePrefix) && name != url.lastPathComponent {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            let persisted = PersistedBaseline(
                version: PersistedBaseline.currentVersion,
                runID: runID,
                taskFolder: baseline.root.standardized,
                entries: baseline.entries
            )
            try JSONEncoder().encode(persisted).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func loadBaseline(at url: URL, runID: UUID) -> BaselineLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(PersistedBaseline.self, from: data),
              persisted.version == PersistedBaseline.currentVersion,
              persisted.runID == runID else {
            return .unreadable
        }
        return .loaded(TaskFolderRunSnapshot(root: .init(persisted.taskFolder), entries: persisted.entries))
    }

    static func removeBaseline(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The runs that left a baseline to replay; one `stat` each, so recovery
    /// is only scheduled when there is something to recover.
    @MainActor
    static func runsWithPersistedBaseline(_ runs: [TaskRun]) -> [TaskRun] {
        runs.filter { run in
            guard let task = run.task else { return false }
            let url = baselineURL(taskFolder: TaskWorkspaceAccess(task: task).taskFolder, runID: run.id)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Compares each interrupted run's persisted baseline with its task folder
    /// as it is now, appends what changed, and removes the baseline — an
    /// unreadable one too. Anything that changed the folder after the crash
    /// and before this launch is attributed to the interrupted run: nothing
    /// on disk tells the two apart.
    @MainActor
    static func recoverInterruptedRuns(_ runs: [TaskRun], modelContext: ModelContext) async {
        var recoveredCount = 0
        for run in runs {
            guard let task = run.task else { continue }
            let access = TaskWorkspaceAccess(task: task)
            let url = baselineURL(taskFolder: access.taskFolder, runID: run.id)
            let runID = run.id
            let recordedJSON = run.fileChangesJSON
            let executionPath = access.effectiveWorkspacePath
            let runStartedAt = run.startedAt
            let started = Date()
            let outcome = await Task.detached(priority: .utility) { () -> Result<Observation, ObservationSkip>? in
                let load = loadBaseline(at: url, runID: runID)
                if case .missing = load { return nil }
                defer { removeBaseline(at: url) }
                guard case .loaded(let before) = load else { return .failure(.unreadableBaseline) }
                return observe(
                    since: before,
                    recordedJSON: recordedJSON,
                    executionPath: executionPath,
                    runStartedAt: runStartedAt,
                    runEndedAt: started
                )
            }.value
            switch outcome {
            case nil:
                continue
            case .failure(let skip):
                logSkipped(task: task, run: run, reason: skip.rawValue, recovered: true)
            case .success(let observation):
                run.appendHostFileChanges(observation.records)
                logObservation(observation, task: task, run: run, started: started, recovered: true)
                recoveredCount += 1
            }
        }
        guard recoveredCount > 0 else { return }
        _ = WorkspacePersistenceCoordinator.saveWithoutAutoExport(
            modelContext: modelContext,
            auditFields: ["operation": "recover_interrupted_run_snapshots"]
        )
    }
}
