import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A transient description of one save, derived only from its changed rows.
/// Read old owners before commit as well: deletion and reparenting can clear
/// the live inverse, and flat workspaceID models have no inverse to inspect.
struct WorkspaceExportChangeScope {
    private var workspaces = Set<UUID>()
    private var globalSkills = Set<UUID>()
    private var globalConnectors = Set<UUID>()
    private var globalTools = Set<UUID>()
    private var all = false

    @MainActor
    static func capture(_ context: ModelContext) -> Self {
        autoreleasepool {
            var result = Self()
            let inserted = context.insertedModelsArray
            let insertedIDs = Set(inserted.map(\.persistentModelID))
            for model in inserted { result.include(model) }
            let previous = ModelContext(context.container)
            previous.autosaveEnabled = false
            for model in context.changedModelsArray + context.deletedModelsArray {
                if !model.isDeleted { result.include(model) }
                if !insertedIDs.contains(model.persistentModelID) {
                    result.includePrevious(model, in: previous)
                }
            }
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

    private mutating func includePrevious<Model: PersistentModel>(_ model: Model, in context: ModelContext) {
        guard !all else { return }
        switch model {
        case is GoogleOAuthAccountProfile, is FeedbackReport, is PersistentStoreMigrationRecord: return
        default: break
        }
        let id = model.persistentModelID
        var descriptor = FetchDescriptor<Model>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        do { if let previous = try context.fetch(descriptor).first { include(previous) } }
        catch {
            all = true // Never accept a possibly crossed save boundary.
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_scope_failed", "model_type": String(describing: Model.self),
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
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
        case let value as TaskTurnRequest: add(taskID: value.taskID, in: value.modelContext)
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

    private mutating func add(taskID: UUID, in context: ModelContext?) {
        guard let context else { all = true; return }
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 1
        do { if let task = try context.fetch(descriptor).first { add(task.workspace) } }
        catch { all = true }
    }

    private mutating func add(_ skill: Skill) {
        add(skill.workspace)
        for task in skill.tasks { add(task.workspace) }
        if skill.isGlobal { globalSkills.insert(skill.id) }
    }
}
