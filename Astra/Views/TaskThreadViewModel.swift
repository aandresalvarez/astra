import Foundation

@Observable @MainActor
final class TaskThreadViewModel {
    private(set) var snapshot: TaskThreadSnapshot?
    private(set) var generatedFilePaths: [String] = []

    private var snapshotTrigger: TaskThreadSnapshotTrigger?
    private var snapshotTask: Task<Void, Never>?
    private var generatedFilesTask: Task<Void, Never>?

    func reset(for task: AgentTask) {
        snapshotTrigger = nil
        snapshotTask?.cancel()
        snapshot = TaskThreadSnapshot.placeholder(goal: task.goal, createdAt: task.createdAt)
        refreshSnapshot(for: task)
        refreshGeneratedFiles(folder: task.taskFolder)
    }

    func refreshSnapshot(for task: AgentTask) {
        let trigger = TaskThreadSnapshotTrigger(task: task)
        guard snapshotTrigger != trigger else { return }
        snapshotTrigger = trigger
        let input = TaskThreadSnapshotInput(task: task)
        let fields = [
            "task_id": String(task.id.uuidString.prefix(8)),
            "event_count": String(trigger.eventCount),
            "run_count": String(trigger.runCount),
            "status": trigger.status.rawValue
        ]

        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            let builtSnapshot = await TaskThreadSnapshot.buildAsync(input: input, fields: fields)
            guard !Task.isCancelled else { return }
            self?.snapshot = builtSnapshot
        }
    }

    func refreshGeneratedFiles(folder: String) {
        generatedFilesTask?.cancel()

        guard !folder.isEmpty else {
            generatedFilePaths = []
            return
        }

        generatedFilesTask = Task { [weak self] in
            let paths = await TaskGeneratedFiles.filesAsync(in: folder)
            guard !Task.isCancelled else { return }
            self?.generatedFilePaths = paths
        }
    }

    func cancelGeneratedFilesRefresh() {
        generatedFilesTask?.cancel()
        generatedFilesTask = nil
    }
}
