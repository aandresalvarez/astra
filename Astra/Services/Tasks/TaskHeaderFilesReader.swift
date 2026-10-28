import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The header reads file facts from its persisted owner, independently of the
/// paged transcript and its presentation cache. All I/O runs off the main actor.
enum TaskHeaderFilesReader {
    static func items(scope: TaskAttachmentHistoryScope, inputs: [String], taskFolder: String,
                      workspacePath: String, modelContext: ModelContext) throws -> [TaskFileItem] {
        let taskID = scope.taskID
        let descriptor = FetchDescriptor<TaskRun>(predicate: #Predicate { $0.task?.id == taskID },
            sortBy: [SortDescriptor(\TaskRun.startedAt, order: .reverse), SortDescriptor(\TaskRun.id, order: .reverse)])
        var changes: [StoredFileChange] = []
        try modelContext.enumerate(descriptor, batchSize: 128) { run in
            try Task.checkCancellation()
            guard !run.isDeleted, let owner = run.task, !owner.isDeleted,
                  owner.persistentModelID == scope.ownerID else { return }
            changes.append(contentsOf: run.fileChanges.reversed())
        }
        try Task.checkCancellation()
        let paths = try TaskAttachmentFilesReader.paths(scope: scope, modelContext: modelContext)
        let generated = TaskGeneratedFiles.files(in: taskFolder, fileManager: .default,
                                                 isCancelled: { Task.isCancelled }) ?? []
        try Task.checkCancellation()
        let indexed = TaskFileIndex.headerItems(fileChanges: changes, generatedFilePaths: generated,
            inputs: inputs, taskFolder: taskFolder, workspacePath: workspacePath)
        return TaskAttachmentFilesReader.merging(paths: paths, with: indexed)
    }
}
