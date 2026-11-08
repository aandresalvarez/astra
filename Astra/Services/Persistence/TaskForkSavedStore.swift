import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Only saved identifiers cross the worker/UI boundary. Managed objects and
/// the private context are destroyed on the worker before returning.
public struct SavedTaskFork: Sendable {
    public let persistentID: PersistentIdentifier
    public let taskID: UUID
    public let workspaceID: PersistentIdentifier?
}

public enum TaskForkSavedStore {
    // Deterministic tests can stop just before commit without blocking MainActor.
    @TaskLocal static var beforeCommit: (@Sendable () throws -> Void)?

    public static func create(
        container: ModelContainer,
        sourceID: PersistentIdentifier,
        targetRunID: PersistentIdentifier,
        options: TaskForkOptions
    ) throws -> SavedTaskFork {
        precondition(!Thread.isMainThread, "Fork construction and save require a worker executor")
        return try autoreleasepool {
            let store = WorkspaceSavedExportSource(container)
            guard store.resolve() != nil else { throw CocoaError(.fileReadUnknown) }
            try Task.checkCancellation()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            guard let source = try context.fetch(FetchDescriptor<AgentTask>(
                predicate: #Predicate { $0.persistentModelID == sourceID })).first,
                  let target = source.runs.first(where: { $0.persistentModelID == targetRunID }) else {
                throw AgentTaskForkError.targetRunMissing
            }
            let workspaceID = source.workspace?.persistentModelID
            let workspacePath = source.workspace?.primaryPath
            let checkout = source.executionRootPath
            let fork = try AgentTaskForkService.fork(from: source, upToRun: target, options: options, in: context)
            let folder = TaskFolderResolvingSeam.required.taskFolder(
                workspacePath: workspacePath ?? "", taskID: fork.id)
            var saved = false
            defer {
                if !saved {
                    context.rollback()
                    if !folder.isEmpty { TaskForkManifestWritingSeam.required.removePreparedFork(taskFolder: folder) }
                }
            }
            try beforeCommit?()
            try Task.checkCancellation()
            guard store.resolve() != nil else { throw CocoaError(.fileReadUnknown) }
            // Navigation is allowed while copying. A deleted/moved source or
            // checkout must not be recreated from the worker's registered graph.
            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            guard let current = try reader.fetch(FetchDescriptor<AgentTask>(
                predicate: #Predicate { $0.persistentModelID == sourceID })).first,
                  current.workspace?.persistentModelID == workspaceID,
                  current.workspace?.primaryPath == workspacePath,
                  current.executionRootPath == checkout,
                  current.runs.contains(where: { $0.persistentModelID == targetRunID }) else {
                throw AgentTaskForkError.targetRunMissing
            }
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                workspace: fork.workspace, modelContext: context, taskID: fork.id,
                auditFields: ["operation": "fork_conversation", "fork_mode": options.mode.rawValue,
                              "git_backed": String(options.repository != nil), "executor": "background"])
            saved = true
            // A background save has no main-context didSave observer. Invalidate
            // unsealed older reads while preserving the last sealed fallback;
            // the main-actor handoff registers the new export obligation.
            if let id = fork.workspace?.id { _ = WorkspaceAutoExportGate.shared.beginRead(for: id.uuidString) }
            return SavedTaskFork(persistentID: fork.persistentModelID, taskID: fork.id, workspaceID: fork.workspace?.persistentModelID)
        }
    }
}
