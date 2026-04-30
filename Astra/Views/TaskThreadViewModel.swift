import Foundation

@Observable @MainActor
final class TaskThreadViewModel {
    private(set) var snapshot: TaskThreadSnapshot?
    private(set) var generatedFilePaths: [String] = []

    private var generatedFilesTask: Task<Void, Never>?

    func reset(for task: AgentTask) {
        refreshSnapshot(for: task)
        refreshGeneratedFiles(folder: task.taskFolder)
    }

    func refreshSnapshot(for task: AgentTask) {
        snapshot = TaskThreadSnapshot(task: task)
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
