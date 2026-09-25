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
/// the pre-run walk and removes it once the run's changes are saved
/// (`settleBaseline`); any left behind are replayed at the next launch by
/// `recoverPersistedBaselines`, before the queue starts.
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

    /// Larger than any baseline a walk within `entryLimit` writes. The task
    /// folder is provider-writable, so a file past this is read as unusable
    /// rather than loaded.
    static let maximumBaselineBytes = 32 * 1_024 * 1_024

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
    /// up, and once this run changes the folder, comparing against it would
    /// attribute this run's changes to that one. So a baseline recovery put
    /// off for the next launch is superseded by the next run of its task.
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximumBaselineBytes,
              let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(PersistedBaseline.self, from: data),
              persisted.version == PersistedBaseline.currentVersion,
              persisted.runID == runID,
              persisted.entries.count <= entryLimit else {
            return .unreadable
        }
        return .loaded(TaskFolderRunSnapshot(root: .init(persisted.taskFolder), entries: persisted.entries))
    }

    static func removeBaseline(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the run's baseline once what it compared is durable: the run
    /// observed its task folder and has nothing left unsaved. Until then the
    /// baseline stays, so a crash before the save leaves recovery something to
    /// replay at the next launch.
    @MainActor
    static func settleBaseline(_ outcome: RecordOutcome, task: AgentTask, run: TaskRun) async {
        guard let baselineURL = outcome.baselineURL, outcome.observed, !run.hasChanges else { return }
        await Task.detached(priority: .utility) { removeBaseline(at: baselineURL) }.value
    }

    /// Tasks changed this recently are searched for baselines at launch. A
    /// baseline left in an older task stays until that task runs again.
    static let recoveryLookback: TimeInterval = 30 * 24 * 60 * 60

    /// Replays every baseline a run left behind, before the queue starts: a
    /// run interrupted by a crash, and a run a quit or a cancel marked done
    /// before its worker got to compare. Each is compared with its task
    /// folder as it is now, the changes are appended and saved (and exported,
    /// when `autoExportWorkspaces`), and only then is the baseline removed.
    /// Anything that changed the folder between the interruption and this
    /// launch is attributed to that run: nothing on disk tells the two apart.
    @MainActor
    static func recoverPersistedBaselines(
        modelContext: ModelContext,
        autoExportWorkspaces: Bool,
        now: Date = Date()
    ) async {
        let cutoff = now.addingTimeInterval(-recoveryLookback)
        let tasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.updatedAt >= cutoff }
        ))) ?? []
        let folders = tasks.map { TaskWorkspaceAccess(task: $0).taskFolder }
        let found = await Task.detached(priority: .utility) {
            folders.enumerated().flatMap { index, folder in
                persistedBaselines(inTaskFolder: folder).map { (taskIndex: index, runID: $0.runID, url: $0.url) }
            }
        }.value
        guard !found.isEmpty else { return }

        var settled: [(url: URL, workspace: Workspace?)] = []
        var discarded: [URL] = []
        for baseline in found {
            let task = tasks[baseline.taskIndex]
            guard let run = task.runs.first(where: { $0.id == baseline.runID }) else {
                discarded.append(baseline.url) // Its run is gone.
                continue
            }
            // A live worker owns its own comparison.
            guard run.status != .running else { continue }
            switch await recover(run, task: task, baselineURL: baseline.url) {
            case .recovered:
                settled.append((baseline.url, task.workspace))
            case .unusable:
                discarded.append(baseline.url)
            case .retryLater:
                continue
            }
        }
        let saved = saveRecovered(settled.map(\.workspace), modelContext: modelContext, autoExport: autoExportWorkspaces)
        let removable = discarded + (saved ? settled.map(\.url) : [])
        await Task.detached(priority: .utility) { removable.forEach(removeBaseline(at:)) }.value
    }

    private enum RecoveryOutcome {
        case recovered
        /// Nothing this baseline could ever tell: unreadable, or another run's.
        case unusable
        /// The folder could not be walked this time; the next launch tries
        /// again, unless a later run of the task supersedes the baseline first.
        case retryLater
    }

    @MainActor
    private static func recover(_ run: TaskRun, task: AgentTask, baselineURL: URL) async -> RecoveryOutcome {
        let runID = run.id
        let recordedJSON = run.fileChangesJSON
        let executionPath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let runStartedAt = run.startedAt
        let started = Date()
        let outcome = await Task.detached(priority: .utility) { () -> Result<Observation, ObservationSkip> in
            guard case .loaded(let before) = loadBaseline(at: baselineURL, runID: runID) else {
                return .failure(.unreadableBaseline)
            }
            return observe(
                since: before,
                recordedJSON: recordedJSON,
                executionPath: executionPath,
                runStartedAt: runStartedAt,
                runEndedAt: started
            )
        }.value
        switch outcome {
        case .success(let observation):
            run.appendHostFileChanges(observation.records)
            logObservation(observation, task: task, run: run, started: started, recovered: true)
            return .recovered
        case .failure(let skip):
            logSkipped(task: task, run: run, reason: skip.rawValue, recovered: true)
            return skip == .unreadableBaseline ? .unusable : .retryLater
        }
    }

    @MainActor
    private static func saveRecovered(_ workspaces: [Workspace?], modelContext: ModelContext, autoExport: Bool) -> Bool {
        guard !workspaces.isEmpty else { return true }
        let auditFields = ["operation": "recover_run_snapshots"]
        guard autoExport else {
            return WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: modelContext, auditFields: auditFields)
        }
        // Export each workspace the recovery touched, so its JSON mirror
        // carries the recovered changes too; one save covers them all.
        var seen = Set<UUID>()
        var saved = true
        for workspace in workspaces {
            guard let workspace else { continue }
            guard seen.insert(workspace.id).inserted else { continue }
            saved = WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: workspace,
                modelContext: modelContext,
                auditFields: auditFields
            ) && saved
        }
        return seen.isEmpty
            ? WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: modelContext, auditFields: auditFields)
            : saved
    }

    /// The baselines in one task folder's `diagnostics/`, by run id.
    static func persistedBaselines(inTaskFolder taskFolder: String) -> [(runID: UUID, url: URL)] {
        let directory = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(baselineFilePrefix), name.hasSuffix(".json"),
                  let runID = UUID(uuidString: String(name.dropFirst(baselineFilePrefix.count).dropLast(5))) else {
                return nil
            }
            return (runID, directory.appendingPathComponent(name))
        }
    }
}
