import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A plugin's templates are still workspace rows, stamped with the plugin
/// and the template's component. Add creates them; an Update brings them to
/// the definition: a declared template is written (created when missing), and
/// a stamped one the definition no longer declares stays as the person's own
/// row, its stamp cleared, never deleted.
@MainActor
enum PluginTemplateSync {
    /// The workspace's rows stamped with `packageID`.
    static func stamped(_ packageID: String, in workspace: Workspace) -> [TaskTemplate] {
        workspace.templates.filter { !$0.isDeleted && $0.originPackageID == packageID }
    }

    /// True when every declared template has a stamped row with its content
    /// and no stamped row names a template the definition dropped.
    static func isInSync(_ package: PluginPackage, in workspace: Workspace) -> Bool {
        let rows = stamped(package.id, in: workspace)
        let declared = Set(package.templates.map(CapabilityResourceOrigin.componentID(for:)))
        guard rows.allSatisfy({ declared.contains($0.originComponentID ?? "") }) else { return false }
        return package.templates.allSatisfy { spec in
            rows.contains { $0.originComponentID == CapabilityResourceOrigin.componentID(for: spec) && matches($0, spec) }
        }
    }

    /// Writes every declared template and unstamps the dropped ones.
    @discardableResult
    static func sync(_ package: PluginPackage, in workspace: Workspace, modelContext: ModelContext) -> [TaskTemplate] {
        let written = package.templates.map { upsert($0, package: package, in: workspace, modelContext: modelContext) }
        let declared = Set(package.templates.map(CapabilityResourceOrigin.componentID(for:)))
        for row in stamped(package.id, in: workspace) where !declared.contains(row.originComponentID ?? "") {
            row.originPackageID = nil
            row.originPackageVersion = nil
            row.originComponentID = nil
            row.originComponentKind = nil
            row.originSourceKind = nil
            row.updatedAt = Date()
        }
        return written
    }

    /// The row for one declared template: the stamped one, else a row of the
    /// same name, else a new one; its content is the definition's.
    static func upsert(
        _ spec: PluginTemplate,
        package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext
    ) -> TaskTemplate {
        let componentID = CapabilityResourceOrigin.componentID(for: spec)
        let template = workspace.templates.first { !$0.isDeleted && $0.originPackageID == package.id && $0.originComponentID == componentID }
            ?? workspace.templates.first { !$0.isDeleted && $0.name == spec.name }
            ?? TaskTemplate(
                name: spec.name,
                mainGoal: spec.mainGoal,
                workspace: workspace,
                icon: spec.icon,
                templateDescription: spec.description
            )
        if template.modelContext == nil {
            modelContext.insert(template)
        }
        template.name = spec.name
        template.icon = spec.icon
        template.templateDescription = spec.description
        template.mainGoal = spec.mainGoal
        template.beforeGoal = spec.beforeGoal
        template.afterGoal = spec.afterGoal
        template.mainBudget = spec.mainBudget
        template.beforeBudget = spec.beforeBudget
        template.afterBudget = spec.afterBudget
        template.variablesJSON = spec.variablesJSON
        template.passContextToMain = spec.passContextToMain
        template.passContextToAfter = spec.passContextToAfter
        CapabilityResourceOrigin.stamp(template, package: package, componentID: componentID)
        template.updatedAt = Date()
        return template
    }

    private static func matches(_ row: TaskTemplate, _ spec: PluginTemplate) -> Bool {
        row.name == spec.name
            && row.icon == spec.icon
            && row.templateDescription == spec.description
            && row.mainGoal == spec.mainGoal
            && row.beforeGoal == spec.beforeGoal
            && row.afterGoal == spec.afterGoal
            && row.mainBudget == spec.mainBudget
            && row.beforeBudget == spec.beforeBudget
            && row.afterBudget == spec.afterBudget
            && row.variablesJSON == spec.variablesJSON
            && row.passContextToMain == spec.passContextToMain
            && row.passContextToAfter == spec.passContextToAfter
    }
}
