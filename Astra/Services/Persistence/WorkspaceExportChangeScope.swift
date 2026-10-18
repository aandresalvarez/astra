import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A transient description of one save, derived only from its changed rows.
/// Read old owners before commit as well: deletion and reparenting can clear
/// the live inverse, and flat workspaceID models have no inverse to inspect.
struct WorkspaceExportChangeScope {
    private static let fetchBatchSize = 256
    private var workspaces = Set<UUID>()
    private var globalSkills = Set<UUID>()
    private var globalConnectors = Set<UUID>()
    private var globalTools = Set<UUID>()
    private var all = false
    // Synchronous query work, retained only for this capture's diagnostics.
    private(set) var previousFetchCount = 0
    private var requestTaskIDs = Set<UUID>()

    @MainActor
    static func capture(_ context: ModelContext) -> Self {
        autoreleasepool {
            var result = Self()
            let inserted = context.insertedModelsArray
            let insertedIDs = Set(inserted.map(\.persistentModelID))
            for model in inserted { result.include(model) }
            var oldRows: [any PersistentModel] = []
            for model in context.changedModelsArray + context.deletedModelsArray {
                if !model.isDeleted { result.include(model) }
                if !insertedIDs.contains(model.persistentModelID) { oldRows.append(model) }
            }
            result.includeRequestOwners(in: context)
            let previous = ModelContext(context.container)
            previous.autosaveEnabled = false
            // Fetch each entity in bounded batches before traversing its
            // relationships. Keep those rows alive so shared ancestors reuse
            // this context's registered models throughout the scope capture.
            let groups = Dictionary(grouping: oldRows) { ObjectIdentifier(type(of: $0)) }
            var savedRows: [any PersistentModel] = []
            for models in groups.values {
                if let model = models.first {
                    savedRows += result.fetchPrevious(models, of: model, in: previous)
                }
            }
            for model in savedRows { result.include(model) }
            result.includeRequestOwners(in: previous, countingPrevious: true)
            return result
        }
    }

    func affects(_ workspace: Workspace?, id: UUID) -> Bool {
        if all || workspaces.contains(id) { return true }
        guard let workspace, !workspace.isDeleted else { return false }
        return !globalSkills.isDisjoint(with: workspace.enabledGlobalSkillIDs.compactMap(UUID.init(uuidString:)))
            || !globalConnectors.isDisjoint(with: workspace.enabledGlobalConnectorIDs.compactMap(UUID.init(uuidString:)))
            || !globalTools.isDisjoint(with: workspace.enabledGlobalToolIDs.compactMap(UUID.init(uuidString:)))
    }

    private mutating func fetchPrevious<Model: PersistentModel>(_ models: [any PersistentModel],
                                                               of model: Model, in context: ModelContext) -> [any PersistentModel] {
        guard !all else { return [] }
        switch model {
        case is GoogleOAuthAccountProfile, is FeedbackReport, is PersistentStoreMigrationRecord: return []
        default: break
        }
        let allIDs = Array(Set(models.map(\.persistentModelID)))
        var rows: [any PersistentModel] = []
        do {
            for offset in stride(from: 0, to: allIDs.count, by: Self.fetchBatchSize) {
                let ids = Array(allIDs[offset..<min(offset + Self.fetchBatchSize, allIDs.count)])
                let descriptor = FetchDescriptor<Model>(predicate: #Predicate { ids.contains($0.persistentModelID) })
                previousFetchCount += 1
                rows += try context.fetch(descriptor)
            }
        }
        catch {
            all = true // Never accept a possibly crossed save boundary.
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_scope_failed", "model_type": String(describing: Model.self),
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        return rows
    }

    private mutating func include(_ model: any PersistentModel) {
        switch model {
        case let value as Workspace: workspaces.insert(value.id)
        case let value as AgentTask: add(value.workspace)
        case let value as TaskRun: add(value.task?.workspace)
        case let value as TaskEvent: add(value.task?.workspace ?? value.run?.task?.workspace)
        case let value as Artifact: add(value.task?.workspace)
        case let value as Skill: add(value)
        case let value as Connector:
            add(value.workspace); if let skill = value.skill { add(skill) }
            if value.isGlobal { globalConnectors.insert(value.id) }
        case let value as LocalTool:
            add(value.workspace); if let skill = value.skill { add(skill) }
            if value.isGlobal { globalTools.insert(value.id) }
        case let value as TaskTemplate: add(value.workspace)
        case let value as TaskSchedule: add(value.workspace)
        case let value as TaskTurnRequest: requestTaskIDs.insert(value.taskID)
        case let value as WorkspaceApp: workspaces.insert(value.workspaceID)
        case let value as WorkspaceAppRun: workspaces.insert(value.workspaceID)
        case let value as WorkspaceAppRunEvent: workspaces.insert(value.workspaceID)
        case let value as WorkspaceAppDependencyBinding: workspaces.insert(value.workspaceID)
        case let value as WorkspaceAppAutomationState: workspaces.insert(value.workspaceID)
        // These rows are deliberately absent from workspace recovery mirrors.
        case is GoogleOAuthAccountProfile, is FeedbackReport, is PersistentStoreMigrationRecord: break
        default: all = true
        }
    }

    private mutating func add(_ workspace: Workspace?) {
        if let workspace { workspaces.insert(workspace.id) }
    }

    private mutating func includeRequestOwners(in context: ModelContext, countingPrevious: Bool = false) {
        let allIDs = Array(requestTaskIDs)
        requestTaskIDs.removeAll()
        do {
            for offset in stride(from: 0, to: allIDs.count, by: Self.fetchBatchSize) {
                let ids = Array(allIDs[offset..<min(offset + Self.fetchBatchSize, allIDs.count)])
                let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { ids.contains($0.id) })
                if countingPrevious { previousFetchCount += 1 }
                for task in try context.fetch(descriptor) { add(task.workspace) }
            }
        }
        catch { all = true }
    }

    private mutating func add(_ skill: Skill) {
        add(skill.workspace)
        for task in skill.tasks { add(task.workspace) }
        if skill.isGlobal { globalSkills.insert(skill.id) }
    }
}
