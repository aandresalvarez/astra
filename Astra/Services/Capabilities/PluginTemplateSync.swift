import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// A plugin's templates are still workspace rows, stamped with the plugin
/// and the template's component. Add creates them; an Update brings them to
/// the definition: a declared template is written (created when missing), and
/// a stamped one the definition no longer declares stays as the person's own
/// row, its stamp cleared, never deleted. A stamped row the person edited
/// since the last sync (its content no longer has the digest the activation
/// recorded) is theirs too: it is unstamped and kept, and the definition's
/// template is written as a new row beside it.
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

    /// Writes every declared template and unstamps the dropped and the
    /// edited ones, then records what it wrote. A template written new takes
    /// the ID `reusingIDs` names for its component (one a Remove deleted, so
    /// a schedule naming it resolves again) when no row has that ID.
    @discardableResult
    static func sync(
        _ package: PluginPackage, in workspace: Workspace, modelContext: ModelContext, reusingIDs: [String: UUID] = [:]
    ) -> [TaskTemplate] {
        let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
        let specs = Dictionary(
            package.templates.map { (CapabilityResourceOrigin.componentID(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for row in stamped(package.id, in: workspace) {
            let componentID = row.originComponentID ?? ""
            guard let spec = specs[componentID] else {
                unstamp(row)
                continue
            }
            if isEdited(row, spec: spec, recorded: activation?.templateDigest(forComponent: componentID)) {
                unstamp(row)
            }
        }
        let written = package.templates.map { spec in
            upsert(spec, package: package, in: workspace, modelContext: modelContext,
                   reusingID: reusingIDs[CapabilityResourceOrigin.componentID(for: spec)])
        }
        if let activation {
            WorkspaceCapabilityActivation.setTemplateDigests(
                Dictionary(
                    written.compactMap { row in row.originComponentID.map { ($0, contentDigest(of: row)) } },
                    uniquingKeysWith: { first, _ in first }
                ),
                on: activation
            )
        }
        return written
    }

    /// Records the digest of each stamped row that still has the
    /// definition's content and none of the person's own settings (the
    /// migration's starting point): a customized row gets no digest, so a
    /// later Remove or Update keeps it.
    static func recordUnedited(_ package: PluginPackage, in workspace: Workspace, on activation: PluginActivation) {
        var digests: [String: String] = [:]
        for spec in package.templates {
            let componentID = CapabilityResourceOrigin.componentID(for: spec)
            guard let row = stamped(package.id, in: workspace).first(where: { $0.originComponentID == componentID }),
                  !isEdited(row, spec: spec, recorded: nil) else { continue }
            digests[componentID] = contentDigest(of: row)
        }
        guard !digests.isEmpty else { return }
        WorkspaceCapabilityActivation.setTemplateDigests(digests, on: activation)
    }

    /// True when the person changed a stamped row since a sync wrote it. A
    /// row with no recorded digest (written before digests were kept) counts
    /// as edited unless it already has the definition's content and none of
    /// the person's own (model overrides, hooks, default skills): keeping a
    /// row is recoverable, overwriting an edit is not.
    static func isEdited(_ row: TaskTemplate, spec: PluginTemplate, recorded: String?) -> Bool {
        if let recorded { return contentDigest(of: row) != recorded }
        return !matches(row, spec) || hasOwnSettings(row)
    }

    /// Whether a row carries settings a plugin template never declares.
    private static func hasOwnSettings(_ row: TaskTemplate) -> Bool {
        !(row.beforeModel.isEmpty && row.mainModel.isEmpty && row.afterModel.isEmpty)
            || !(row.hooksJSON.isEmpty || row.hooksJSON == "{}")
            || !row.defaultSkillIDs.isEmpty
    }

    /// `isEdited` for a stamped row of `package`, whose declared template
    /// may be gone: a row without a digest or a template to compare with is
    /// counted as edited, so Remove keeps it.
    static func isEdited(_ row: TaskTemplate, of package: PluginPackage, recorded: String?) -> Bool {
        guard let spec = package.templates.first(where: { CapabilityResourceOrigin.componentID(for: $0) == row.originComponentID }) else {
            return recorded.map { contentDigest(of: row) != $0 } ?? true
        }
        return isEdited(row, spec: spec, recorded: recorded)
    }

    /// A digest of everything the person can edit on a row
    /// (`WorkspaceCapabilityActivation.templateContentDigest`).
    static func contentDigest(of row: TaskTemplate) -> String {
        WorkspaceCapabilityActivation.templateContentDigest(of: row)
    }

    /// Makes a row the person's own: it no longer names the plugin.
    static func unstamp(_ row: TaskTemplate) {
        row.originPackageID = nil
        row.originPackageVersion = nil
        row.originComponentID = nil
        row.originComponentKind = nil
        row.originSourceKind = nil
        row.updatedAt = Date()
    }

    /// The row for one declared template: the one stamped with this plugin
    /// and component, else a new one; its content is the definition's. A
    /// same-named row the person authored is never taken over.
    static func upsert(
        _ spec: PluginTemplate,
        package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext,
        reusingID: UUID? = nil
    ) -> TaskTemplate {
        let componentID = CapabilityResourceOrigin.componentID(for: spec)
        let template = workspace.templates.first { !$0.isDeleted && $0.originPackageID == package.id && $0.originComponentID == componentID }
            ?? TaskTemplate(
                name: spec.name,
                mainGoal: spec.mainGoal,
                workspace: workspace,
                icon: spec.icon,
                templateDescription: spec.description
            )
        if template.modelContext == nil {
            // Never an ID a stored row still has: the person's rows are theirs.
            if let reusingID, ((try? modelContext.fetch(FetchDescriptor<TaskTemplate>(predicate: #Predicate { $0.id == reusingID })))?.isEmpty ?? false) {
                template.id = reusingID
            }
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

    static func matches(_ row: TaskTemplate, _ spec: PluginTemplate) -> Bool {
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
