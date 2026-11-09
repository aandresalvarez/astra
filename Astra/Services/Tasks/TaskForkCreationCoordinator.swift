import Foundation
import Observation
import SwiftData
import ASTRAModels
import ASTRAPersistence

@MainActor
@Observable
final class TaskForkCreationCoordinator {
    static let shared = TaskForkCreationCoordinator()
    @TaskLocal static var saveFork: @Sendable (ModelContainer, PersistentIdentifier, PersistentIdentifier, TaskForkOptions) throws -> SavedTaskFork = {
        try TaskForkSavedStore.create(container: $0, sourceID: $1, targetRunID: $2, options: $3)
    }
    private(set) var activeSources: Set<PersistentIdentifier> = []
    @ObservationIgnored private var workers: [PersistentIdentifier: Task<SavedTaskFork, Error>] = [:]

    enum CreationError: LocalizedError {
        case alreadyCreating
        case savedForkUnavailable
        var errorDescription: String? {
            switch self {
            case .alreadyCreating: "A fork of this conversation is already being created."
            case .savedForkUnavailable: "The fork was saved, but could not be opened. Find it in the workspace task list."
            }
        }
    }

    static var hasActiveForks: Bool { !shared.activeSources.isEmpty }

    /// Quit cancels uncommitted work and waits for its cleanup. A committed
    /// fork always registers its export before this drain can finish.
    static func cancelAndDrain() async {
        while !shared.workers.isEmpty {
            let workers = Array(shared.workers.values)
            workers.forEach { $0.cancel() }
            for worker in workers { _ = try? await worker.value }
            await Task.yield()
        }
    }

    static func create(
        source: AgentTask,
        targetRun: TaskRun,
        mode: TaskForkMode,
        policy: TaskForkPolicy,
        modelContext: ModelContext
    ) async throws -> AgentTask {
        guard policy.allowedModes.contains(mode) else { throw AgentTaskForkError.repositoryFileCopyDenied }
        guard !shared.activeSources.contains(source.persistentModelID) else { throw CreationError.alreadyCreating }
        // Preserve the previous command's pending-edit semantics before taking
        // a saved snapshot. No copied history is ever inserted on MainActor.
        if modelContext.hasChanges {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: source.workspace, modelContext: modelContext,
                auditFields: ["operation": "fork_source_checkpoint"])
        }
        let sourceID = source.persistentModelID
        guard shared.activeSources.insert(sourceID).inserted else { throw CreationError.alreadyCreating }
        defer {
            shared.workers[sourceID] = nil
            shared.activeSources.remove(sourceID)
        }
        let targetID = targetRun.persistentModelID
        let container = modelContext.container
        let options = TaskForkOptions(mode: mode, repository: policy.repository)
        let saveFork = saveFork
        let worker = Task.detached(priority: .userInitiated) {
            try saveFork(container, sourceID, targetID, options)
        }
        shared.workers[sourceID] = worker
        let saved = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        // Even cancellation after commit must finish this handoff. Export owns
        // its own task and reads durable state, not the UI context's new edits.
        let workspace: Workspace?
        if let workspaceID = saved.workspaceID {
            // Refetch the existing UI owner, including its task membership.
            // A background commit does not refresh a previously loaded inverse
            // merely because the newly saved task is fetched. This reads saved
            // state without resetting the context or discarding pending edits.
            var descriptor = FetchDescriptor<Workspace>(
                predicate: #Predicate { $0.persistentModelID == workspaceID })
            descriptor.relationshipKeyPathsForPrefetching = [\.tasks]
            workspace = try modelContext.fetch(descriptor).first
        } else {
            workspace = nil
        }
        WorkspacePersistenceCoordinator.scheduleSavedMirrorExport(
            workspace: workspace, modelContext: modelContext)
        let id = saved.persistentID
        guard let fork = try modelContext.fetch(FetchDescriptor<AgentTask>(
            predicate: #Predicate { $0.persistentModelID == id })).first else {
            throw CreationError.savedForkUnavailable
        }
        return fork
    }

}
