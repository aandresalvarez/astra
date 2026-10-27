import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The header reads file facts from its persisted owner, independently of the
/// paged transcript and its presentation cache. All I/O runs off the main actor.
enum TaskHeaderFilesReader {
    struct Facts: Sendable {
        var items: [TaskFileItem]
        var userProvidedPaths: Set<String> = []

        static func pathIdentity(_ path: String) -> String {
            URL(fileURLWithPath: TaskFileIndex.normalizedPath(path)).standardizedFileURL.path
        }
    }

    static func items(scope: TaskAttachmentHistoryScope, inputs: [String], taskFolder: String,
                      workspacePath: String, modelContext: ModelContext) throws -> [TaskFileItem] {
        try facts(scope: scope, inputs: inputs, taskFolder: taskFolder,
                  workspacePath: workspacePath, modelContext: modelContext).items
    }

    static func facts(scope: TaskAttachmentHistoryScope, inputs: [String], taskFolder: String,
                      workspacePath: String, modelContext: ModelContext) throws -> Facts {
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
        return Facts(items: TaskAttachmentFilesReader.merging(paths: paths, with: indexed),
                     userProvidedPaths: try providedPaths(inputs + paths, discovered: generated))
    }

    /// Discovery resolves symlinks. Keep the same identity for supplied files
    /// and their descendants, without performing filesystem work during render.
    private static func providedPaths(_ paths: [String], discovered: [String]) throws -> Set<String> {
        var roots: Set<String> = []
        for path in paths where !path.isEmpty {
            try Task.checkCancellation()
            let identity = Facts.pathIdentity(path)
            roots.insert(identity)
            roots.insert(URL(fileURLWithPath: identity).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        var provided = roots
        for path in discovered {
            try Task.checkCancellation()
            let identity = Facts.pathIdentity(path)
            var ancestor = identity
            while !ancestor.isEmpty {
                if roots.contains(ancestor) {
                    provided.insert(identity)
                    break
                }
                guard ancestor != "/" else { break }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        return provided
    }
}
