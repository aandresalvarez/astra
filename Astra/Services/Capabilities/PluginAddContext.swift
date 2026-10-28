import Foundation
import SwiftData
import ASTRAModels

/// Add owns its save. An unrelated task's pending events or editor draft must
/// neither block it nor be committed or rolled back by it.
@MainActor
enum PluginAddContext {
    static func perform<Result>(workspace: Workspace, context: ModelContext,
        _ body: (Workspace, ModelContext) throws -> Result) throws -> Result {
        guard context.hasChanges else { return try body(workspace, context) }
        // Onboarding has no saved workspace to refetch. The installer's existing
        // guard permits only that new workspace and rejects unrelated edits.
        if context.insertedModelsArray.contains(where: { ($0 as? Workspace) === workspace }) {
            return try body(workspace, context)
        }
        guard workspace.modelContext === context, !workspace.isDeleted else {
            throw PluginOperations.OperationError.workspaceChanged
        }
        // Never silently substitute saved plugin/account edits for what the
        // person sees. Task/run/event changes and workspace metadata are separate.
        let pending = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        guard !pending.contains(where: isPluginEdit) else { throw PluginOperations.OperationError.pendingEdits }
        for edited in pending.compactMap({ $0 as? Workspace }) {
            try PluginActivationAdmission.requireCurrent(in: edited, modelContext: context)
        }
        try PluginActivationAdmission.requireCurrent(in: workspace, modelContext: context)
        let owned = ModelContext(context.container)
        owned.autosaveEnabled = false
        let id = workspace.id
        var query = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let matches = try owned.fetch(query)
        guard matches.count == 1, let saved = matches.first,
              saved.primaryPath == workspace.primaryPath else {
            throw PluginOperations.OperationError.workspaceChanged
        }
        let before = Dictionary(try owned.fetch(FetchDescriptor<Workspace>()).map {
            ($0.id, WorkspaceCapabilityActivation.snapshot($0))
        }, uniquingKeysWith: { first, _ in first })
        do {
            let result = try body(saved, owned)
            try refreshCommittedGraph(before: before, into: context)
            return result
        } catch {
            // A mirror error may follow a durable commit. Refresh only saved
            // state, so a retry cannot restore the previous credential owner.
            try? refreshCommittedGraph(before: before, into: context)
            throw error
        }
    }

    private static func refreshCommittedGraph(before: [UUID: WorkspaceCapabilityActivation.Snapshot],
        into context: ModelContext) throws {
        let saved = ModelContext(context.container)
        saved.autosaveEnabled = false
        let changed = try saved.fetch(FetchDescriptor<Workspace>()).filter {
            before[$0.id] != WorkspaceCapabilityActivation.snapshot($0)
        }
        guard !changed.isEmpty else { return }
        let dirtyIDs = Set(context.changedModelsArray.compactMap { ($0 as? Workspace)?.id })
        let visible = try context.fetch(FetchDescriptor<Workspace>())
        // Refetching clean records merges their saved attributes. A dirty
        // workspace deliberately retains its own draft, including relationships;
        // refresh only its plugin relationships and capability-owned fields.
        let activations = try context.fetch(FetchDescriptor<PluginActivation>())
        let accounts = try context.fetch(FetchDescriptor<Connector>())
        let templates = try context.fetch(FetchDescriptor<TaskTemplate>())
        _ = try context.fetch(FetchDescriptor<TaskSchedule>())
        for stored in changed {
            guard let workspace = visible.first(where: { $0.id == stored.id }) else { continue }
            let draftDate = workspace.updatedAt
            let enabled = activations.filter { $0.workspace?.id == workspace.id }
            if workspace.pluginActivations.map(\.id) != enabled.map(\.id) { workspace.pluginActivations = enabled }
            let connectors = accounts.filter { $0.workspace?.id == workspace.id }
            if Set(workspace.connectors.map(\.id)) != Set(connectors.map(\.id)) { workspace.connectors = connectors }
            let ownedTemplates = templates.filter { $0.workspace?.id == workspace.id }
            if Set(workspace.templates.map(\.id)) != Set(ownedTemplates.map(\.id)) { workspace.templates = ownedTemplates }
            WorkspaceCapabilityActivation.restore(WorkspaceCapabilityActivation.snapshot(stored), to: workspace)
            if dirtyIDs.contains(workspace.id), workspace.updatedAt != draftDate { workspace.updatedAt = draftDate }
        }
    }

    private static func isPluginEdit(_ model: any PersistentModel) -> Bool {
        model is Connector || model is PluginActivation || model is AccountBinding
            || model is Skill || model is LocalTool || model is TaskTemplate || model is TaskSchedule
    }
}
